// SSE (Server-Sent Events) client wrapper

class SSEClient {
  constructor(url, handlers = {}) {
    this.url = url;
    this.handlers = handlers;
    this.eventSource = null;
  }

  connect() {
    this.eventSource = new EventSource(this.url);

    this.eventSource.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onMessage) this.handlers.onMessage(data);
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    };

    this.eventSource.addEventListener('iteration', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onIteration) this.handlers.onIteration(data);
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    });

    this.eventSource.addEventListener('chunk', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onChunk) this.handlers.onChunk(data);
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    });

    this.eventSource.addEventListener('backend_retry', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onRetry) this.handlers.onRetry(data);
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    });

    this.eventSource.addEventListener('run_end', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onRunEnd) this.handlers.onRunEnd(data);
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    });

    this.eventSource.addEventListener('run_complete', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onComplete) this.handlers.onComplete(data);
        this.close();
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
    });

    this.eventSource.addEventListener('run_error', (event) => {
      try {
        const data = JSON.parse(event.data);
        if (this.handlers.onError) this.handlers.onError(new Error(data.error || data.message || 'Unknown error'));
      } catch (err) {
        if (this.handlers.onError) this.handlers.onError(err);
      }
      this.close();
    });

    this.eventSource.onerror = () => {
      if (this.handlers.onDisconnect) this.handlers.onDisconnect();
      this.close();
    };
  }

  close() {
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
  }

  get connected() {
    return this.eventSource !== null && this.eventSource.readyState !== EventSource.CLOSED;
  }
}
