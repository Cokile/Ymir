import { setTimeout as waitBeforeRetry } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';

const maxRetries = 2;

// Retry only an explicit rejection while Copilot was reading the upload. A
// network failure or a failed response stream may already have run inference.
// Keep the serialized body, request/session IDs and lifecycle settings intact.
export async function fetchCopilotResponsesWithRetry(fetchUpstream, input, init, options, {
  payload, traceId,
} = {}, {
  wait = waitBeforeRetry, log = console.info, now = () => performance.now(),
} = {}) {
  const diagnosticId = randomUUID();
  const started = now();
  let attempt = 0;
  const emit = (event, fields = {}) => {
    // Diagnostics must never turn a valid model request into a failure.
    try {
      log(`Ymir request: ${JSON.stringify({
        timestamp: new Date().toISOString(), event, diagnostic_id: diagnosticId,
        trace_id: shortText(traceId), ...fields,
      })}`);
    } catch {}
  };
  const elapsed = start => Math.max(0, Math.round(now() - start));
  const headers = new Headers(init.headers);
  let upstreamHost = null;
  try { upstreamHost = new URL(input).hostname; } catch {}
  emit('request_started', {
    ...summarizePayload(payload),
    body_bytes: typeof init.body === 'string' ? Buffer.byteLength(init.body, 'utf8') : null,
    upstream_host: upstreamHost,
    sent_request_id: shortText(headers.get('x-request-id')),
    interaction_id: shortText(headers.get('x-interaction-id')),
    headers_timeout_ms: options.headersTimeoutMs,
    stream_inactivity_timeout_ms: options.streamInactivityTimeoutMs,
    max_attempts: maxRetries + 1, node_version: process.version, pid: process.pid,
  });
  try {
    for (attempt = 1; ; attempt++) {
      options.clientSignal?.throwIfAborted();
      const attemptStarted = now();
      emit('attempt_started', { attempt });
      const response = await fetchUpstream(input, init, options);
      const responseDetails = {
        attempt, status: response.status, headers_ms: elapsed(attemptStarted),
        upstream_request_id: shortText(response.headers.get('x-request-id')),
        upstream_oai_request_id: shortText(response.headers.get('x-oai-request-id')),
      };
      emit('attempt_response', responseDetails);

      let errorCode = null;
      if (response.status === 408 && typeof init.body === 'string') {
        try { errorCode = safeCode((await response.clone().json())?.error?.code); }
        catch { /* Leave unrecognized or unreadable errors to the gateway. */ }
      }
      const retryable = response.status === 408 && errorCode === 'user_request_timeout';
      if (!retryable || attempt > maxRetries) {
        emit(response.ok ? 'request_accepted' : 'request_rejected', {
          ...responseDetails, total_ms: elapsed(started), error_code: errorCode,
          retries_exhausted: retryable && attempt > maxRetries,
        });
        return response;
      }

      // The clone has drained the error response. Release the original branch
      // before waiting so its upstream connection/lifecycle can be cleaned up.
      await response.body?.cancel();
      options.clientSignal?.throwIfAborted();
      const delayMs = 500 * 2 ** (attempt - 1);
      emit('retry_scheduled', { ...responseDetails, error_code: errorCode, delay_ms: delayMs });
      await wait(delayMs, undefined, { signal: options.clientSignal });
    }
  } catch (error) {
    emit(options.clientSignal?.aborted || error?.name === 'AbortError' ? 'request_cancelled' : 'request_failed', {
      attempt, total_ms: elapsed(started), error_name: safeCode(error?.name),
      error_code: safeCode(error?.code), cause_code: safeCode(error?.cause?.code),
    });
    throw error;
  }
}

const shortText = value => typeof value === 'string' ? value.slice(0, 200) : null;
const safeCode = value => typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,128}$/.test(value) ? value : null;

// Reuse the parsed payload; never parse/stringify a large body a second time.
// Only counts and sizes are emitted, including for encrypted reasoning.
function summarizePayload(payload) {
  const items = Array.isArray(payload?.input) ? payload.input : [];
  let reasoningItems = 0, reasoningBytes = 0, images = 0, toolOutputs = 0;
  for (const item of items) {
    if (item?.type === 'reasoning') {
      reasoningItems++;
      if (typeof item.encrypted_content === 'string') reasoningBytes += Buffer.byteLength(item.encrypted_content, 'utf8');
    }
    if (item?.type === 'function_call_output') toolOutputs++;
    if (Array.isArray(item?.content)) images += item.content.filter(part => part?.type === 'input_image').length;
  }
  return {
    model: shortText(payload?.model), stream: payload?.stream === true,
    input_items: typeof payload?.input === 'string' ? 1 : items.length,
    tools: Array.isArray(payload?.tools) ? payload.tools.length : 0,
    reasoning_items: reasoningItems, encrypted_reasoning_bytes: reasoningBytes,
    images, tool_output_items: toolOutputs,
  };
}

const marker = '// Ymir: Retry explicit Copilot request-body timeouts before streaming.';
const transportStart = 'const createHttpResponses = async (payload, headers, clientSignal) => {';
const transportEnd = 'const prepareResponsesWebSocketRequest =';
const nativeCall = `const response = await fetchUpstreamWithLifecycle(\`\${copilotBaseUrl(state)}/responses\`, {
\t\tmethod: "POST",
\t\theaders,
\t\tbody: JSON.stringify(payload)
\t}, {
\t\tclientSignal,
\t\theadersTimeoutMs: transportConfig.headersTimeoutMs,
\t\tstreamInactivityTimeoutMs: transportConfig.streamInactivityTimeoutMs
\t});`;

export function adaptCopilotRequestRetry(source) {
  if (source.includes(marker)) return source;
  const start = source.indexOf(transportStart);
  const end = source.indexOf(transportEnd, start);
  const transport = source.slice(start, end);
  if (source.split(transportStart).length !== 2 || source.split(transportEnd).length !== 2
      || end <= start || transport.split(nativeCall).length !== 2) {
    throw new Error('Ymir could not add Copilot timeout recovery: the HTTP Responses transport changed.');
  }
  const adapterURL = import.meta.url;
  const adapted = transport.replace(nativeCall,
    `${marker}\n\t${nativeCall.replace('fetchUpstreamWithLifecycle(', 'ymirFetchCopilotResponses(fetchUpstreamWithLifecycle, ')
      .replace(/\}\);$/, '}, { payload, traceId: requestContext.getStore()?.traceId });')}`);
  return `import { fetchCopilotResponsesWithRetry as ymirFetchCopilotResponses } from ${JSON.stringify(adapterURL)};\n`
    + source.slice(0, start) + adapted + source.slice(end);
}
