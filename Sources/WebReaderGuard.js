// All Web surfaces are readers. Native URLSession owns the talk mutations.
(() => {
  const denied = () => new DOMException("Pocket Web screens are read-only", "NotAllowedError");
  const allowed = method => String(method || "GET").toUpperCase() === "GET";
  const originalFetch = window.fetch.bind(window);
  window.fetch = (input, init) => {
    const method = init?.method ?? (input instanceof Request ? input.method : "GET");
    return allowed(method) ? originalFetch(input, init) : Promise.reject(denied());
  };
  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url, ...args) {
    if (!allowed(method)) throw denied();
    return originalOpen.call(this, method, url, ...args);
  };
  navigator.sendBeacon = () => false;
  HTMLFormElement.prototype.submit = function() { throw denied(); };
  HTMLFormElement.prototype.requestSubmit = function() { throw denied(); };
  document.addEventListener("submit", event => event.preventDefault(), true);
  window.WebSocket = class { constructor() { throw denied(); } };
})();
