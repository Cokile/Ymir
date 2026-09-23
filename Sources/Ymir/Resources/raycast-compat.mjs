// Raycast speaks Chat Completions. Copilot also has Responses-only models.
// This adapter is mounted only at /raycast/v1; existing clients keep their routes.

function invalid(message) {
  return Object.assign(new Error(message), { status: 400 });
}

export function toResponses(payload) {
  if (!Array.isArray(payload.messages)) throw invalid('messages must be an array');
  if (payload.n != null && payload.n !== 1) throw invalid('Only n=1 is supported');
  const input = [];
  for (const message of payload.messages) {
    if (message.role === 'tool') {
      input.push({ type: 'function_call_output', call_id: message.tool_call_id,
        output: typeof message.content === 'string' ? message.content : JSON.stringify(message.content ?? '') });
      continue;
    }
    if (!['system', 'developer', 'user', 'assistant'].includes(message.role)) {
      throw invalid(`Unsupported message role: ${message.role}`);
    }
    const parts = typeof message.content === 'string'
      ? [{ type: 'text', text: message.content }] : (message.content ?? []);
    const content = parts.map(part => {
      if (part.type === 'text') return message.role === 'assistant'
        ? { type: 'output_text', text: part.text, annotations: [] }
        : { type: 'input_text', text: part.text };
      if (part.type === 'image_url' && message.role === 'user') {
        return { type: 'input_image', image_url: part.image_url.url, detail: part.image_url.detail ?? 'auto' };
      }
      throw invalid(`Unsupported content type: ${part.type}`);
    });
    if (content.length) input.push({ type: 'message', role: message.role, content });
    for (const call of message.tool_calls ?? []) {
      if (call.type !== 'function') throw invalid('Only function tools are supported');
      input.push({ type: 'function_call', call_id: call.id, name: call.function.name, arguments: call.function.arguments });
    }
  }
  const result = { model: payload.model, input, stream: !!payload.stream, store: false };
  const max = payload.max_completion_tokens ?? payload.max_tokens;
  if (max != null) result.max_output_tokens = max;
  for (const key of ['temperature', 'top_p', 'parallel_tool_calls']) {
    if (payload[key] != null) result[key] = payload[key];
  }
  if (payload.reasoning_effort) result.reasoning = { effort: payload.reasoning_effort };
  if (payload.tools) result.tools = payload.tools.map(tool => {
    if (tool.type !== 'function') throw invalid('Only function tools are supported');
    return { type: 'function', ...tool.function };
  });
  if (payload.tool_choice != null) result.tool_choice = typeof payload.tool_choice === 'string'
    ? payload.tool_choice : { type: 'function', name: payload.tool_choice.function.name };
  if (payload.response_format?.type === 'json_schema') {
    result.text = { format: { type: 'json_schema', ...payload.response_format.json_schema } };
  } else if (payload.response_format) {
    result.text = { format: payload.response_format };
  }
  return result;
}

function usageFromResponses(usage) {
  if (!usage) return undefined;
  return {
    prompt_tokens: usage.input_tokens ?? 0,
    completion_tokens: usage.output_tokens ?? 0,
    total_tokens: usage.total_tokens ?? ((usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)),
    prompt_tokens_details: usage.input_tokens_details,
    completion_tokens_details: usage.output_tokens_details,
  };
}

function finishReason(response, hasTools) {
  if (response.status === 'incomplete') return response.incomplete_details?.reason === 'content_filter' ? 'content_filter' : 'length';
  return hasTools ? 'tool_calls' : 'stop';
}

export function toChatCompletion(response, model) {
  if (response.error || response.status === 'failed') throw new Error(response.error?.message ?? 'Upstream response failed');
  const parts = (response.output ?? []).filter(item => item.type === 'message').flatMap(item => item.content ?? []);
  const calls = (response.output ?? []).filter(item => item.type === 'function_call').map(item => ({
    id: item.call_id, type: 'function', function: { name: item.name, arguments: item.arguments },
  }));
  const message = { role: 'assistant', content: parts.filter(p => p.type === 'output_text').map(p => p.text).join('') || null };
  const refusal = parts.filter(p => p.type === 'refusal').map(p => p.refusal).join('');
  if (refusal) message.refusal = refusal;
  if (calls.length) message.tool_calls = calls;
  return {
    id: response.id, object: 'chat.completion', created: response.created_at ?? Math.floor(Date.now() / 1000), model,
    choices: [{ index: 0, message, finish_reason: finishReason(response, calls.length > 0) }],
    usage: usageFromResponses(response.usage),
  };
}

export function toChatStream(upstream, payload) {
  const reader = upstream.body.getReader();
  const encoder = new TextEncoder();
  let cancelled = false;
  const body = new ReadableStream({
    async start(controller) {
      let id = `chatcmpl-ymir-${crypto.randomUUID()}`;
      let created = Math.floor(Date.now() / 1000);
      let terminal = false;
      let sentRole = false;
      let sentText = false;
      let sentRefusal = false;
      const calls = new Map();
      const send = value => { if (!cancelled) controller.enqueue(encoder.encode(`data: ${typeof value === 'string' ? value : JSON.stringify(value)}\n\n`)); };
      const chunk = (delta, finish_reason = null) => ({ id, object: 'chat.completion.chunk', created,
        model: payload.model, choices: [{ index: 0, delta, finish_reason }] });
      const emit = delta => {
        if (!sentRole) { send(chunk({ role: 'assistant', content: '' })); sentRole = true; }
        send(chunk(delta));
      };
      const addCall = item => {
        if (calls.has(item.id)) return calls.get(item.id);
        const entry = { index: calls.size, arguments: '' };
        calls.set(item.id, entry);
        emit({ tool_calls: [{ index: entry.index, id: item.call_id, type: 'function', function: { name: item.name, arguments: '' } }] });
        return entry;
      };
      const event = data => {
        if (!data || data === '[DONE]' || terminal) return;
        const value = JSON.parse(data);
        if (value.response?.id) id = value.response.id;
        if (value.response?.created_at) created = value.response.created_at;
        if (value.type === 'error' || value.type === 'response.failed') {
          throw new Error(value.error?.message ?? value.response?.error?.message ?? value.message ?? 'Upstream stream failed');
        }
        if (value.type === 'response.output_text.delta') {
          sentText = true; emit({ content: value.delta });
        } else if (value.type === 'response.refusal.delta') {
          sentRefusal = true; emit({ refusal: value.delta });
        } else if (value.type === 'response.output_item.added' && value.item?.type === 'function_call') {
          addCall(value.item);
        } else if (value.type === 'response.function_call_arguments.delta') {
          const entry = calls.get(value.item_id);
          if (!entry) throw new Error('Tool argument event arrived without a function call');
          entry.arguments += value.delta;
          emit({ tool_calls: [{ index: entry.index, function: { arguments: value.delta } }] });
        } else if (value.type === 'response.completed' || value.type === 'response.incomplete') {
          const response = value.response;
          const final = toChatCompletion(response, payload.model);
          const message = final.choices[0].message;
          if (!sentText && message.content) emit({ content: message.content });
          if (!sentRefusal && message.refusal) emit({ refusal: message.refusal });
          for (const item of response.output ?? []) {
            if (item.type !== 'function_call') continue;
            const entry = addCall(item);
            if (!entry.arguments && item.arguments) emit({ tool_calls: [{ index: entry.index, function: { arguments: item.arguments } }] });
          }
          send(chunk({}, final.choices[0].finish_reason));
          if (payload.stream_options?.include_usage && final.usage) {
            send({ ...chunk({}), choices: [], usage: final.usage });
          }
          send('[DONE]');
          terminal = true;
        }
      };
      try {
        const decoder = new TextDecoder();
        let buffer = '';
        let data = [];
        const line = value => {
          if (!value) { event(data.join('\n')); data = []; }
          else if (value.startsWith('data:')) data.push(value.slice(5).replace(/^ /, ''));
        };
        while (!cancelled && !terminal) {
          const { value, done } = await reader.read();
          buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
          let index;
          while ((index = buffer.indexOf('\n')) >= 0) {
            line(buffer.slice(0, index).replace(/\r$/, ''));
            buffer = buffer.slice(index + 1);
          }
          if (done) {
            if (buffer) line(buffer.replace(/\r$/, ''));
            line('');
            break;
          }
        }
        if (!terminal && !cancelled) throw new Error('Upstream stream ended before completion');
      } catch (error) {
        if (!cancelled) { send({ error: { message: error.message, type: 'upstream_error' } }); send('[DONE]'); }
      } finally {
        await reader.cancel().catch(() => {});
        if (!cancelled) controller.close();
      }
    },
    cancel() { cancelled = true; return reader.cancel(); },
  });
  return new Response(body, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' } });
}

export async function handleRaycastRequest(request, dispatch) {
  try {
    const url = new URL(request.url);
    const headers = new Headers(request.headers);
    headers.delete('content-length');
    headers.delete('content-encoding');
    const send = (path, payload) => dispatch(new Request(new URL(path, url), {
      method: payload === undefined ? 'GET' : 'POST', headers,
      body: payload === undefined ? undefined : JSON.stringify(payload), signal: request.signal,
    }));
    if (request.method === 'GET') return await send('/v1/models');
    const payload = await request.json();
    const catalog = await send('/v1/models');
    if (!catalog.ok) return catalog;
    const model = (await catalog.json()).data.find(item => item.id === payload.model);
    const endpoints = model?.supported_endpoints ?? [];
    if (!model) throw invalid(`Unknown Ymir model: ${payload.model}`);
    if (endpoints.includes('/chat/completions')) return await send('/v1/chat/completions', payload);
    if (!endpoints.includes('/responses') && !endpoints.includes('/v1/messages')) {
      throw invalid(`Model ${payload.model} does not support chat`);
    }
    const upstream = await send('/v1/responses', toResponses(payload));
    if (!upstream.ok) return upstream;
    if (payload.stream) {
      if (!upstream.headers.get('content-type')?.includes('text/event-stream')) throw new Error('Expected an upstream event stream');
      return toChatStream(upstream, payload);
    }
    return Response.json(toChatCompletion(await upstream.json(), payload.model));
  } catch (error) {
    return Response.json({ error: { message: error.message, type: error.status === 400 ? 'invalid_request_error' : 'upstream_error' } }, { status: error.status ?? 502 });
  }
}
