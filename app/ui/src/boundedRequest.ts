/** Bound both headers and body consumption. A timeout is never a retry. */
export async function boundedRequest(
  input: RequestInfo | URL,
  init: RequestInit = {},
  timeoutMs = 5_000,
): Promise<Response> {
  const controller = new AbortController();
  const upstream = init.signal;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let rejectCancelled: (reason: unknown) => void = () => undefined;
  const cancelled = new Promise<never>((_, reject) => { rejectCancelled = reject; });
  const cancel = () => {
    controller.abort();
    rejectCancelled(new DOMException("Request cancelled or deadline exceeded", "AbortError"));
  };
  upstream?.addEventListener("abort", cancel, { once: true });
  if (upstream?.aborted) cancel();
  timer = setTimeout(cancel, timeoutMs);
  try {
    if (controller.signal.aborted) return await cancelled;
    return await Promise.race([
      (async () => {
        const response = await fetch(input, { ...init, signal: controller.signal });
        const bytes = await response.arrayBuffer();
        return new Response(bytes.byteLength ? bytes : null, {
          status: response.status, statusText: response.statusText, headers: response.headers,
        });
      })(),
      cancelled,
    ]);
  } finally {
    clearTimeout(timer);
    upstream?.removeEventListener("abort", cancel);
  }
}
