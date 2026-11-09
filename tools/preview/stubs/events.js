// useEvents(): the page's hook bus; the preview (and Playwright) fires them with window.__emit(name, data)
const handlers = {}
export function useEvents() {
  return {
    on(name, fn) { (handlers[name] ||= []).push(fn) },
    off(name, fn) { handlers[name] = (handlers[name] || []).filter(f => f !== fn) },
    emit(name, data) { (handlers[name] || []).forEach(f => f(data)) },
  }
}
if (typeof window !== "undefined") window.__emit = (name, data) => (handlers[name] || []).forEach(f => f(data))
