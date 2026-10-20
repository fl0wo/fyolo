// Module hooks registered only inside a Vitest process (see preload.cjs).
//
// Vitest builds its Vite configs through `resolveConfig` / `createServer` from
// 'vite'. When the importer is Vitest itself, 'vite' resolves to a shim. The shim
// re-exports the real module (same instance, so Vite stays a singleton) and appends
// one plugin to every inline config it sees. That plugin's `configureVitest` hook
// adds fyolo's reporter beside the user's own. A CLI `--reporter` would replace
// those, so it is not used.
//
// Vitest 5 resolves the config first and passes the *resolved* config to
// `createServer`. Its `getSortedPluginHooks` is bound to the plugin list as it was
// at resolution, so the plugin has to be added at `resolveConfig`. A config that is
// already resolved is passed through untouched.

const SHIM_QUERY = 'fyolo-vite-shim';

export async function resolve(specifier, context, nextResolve) {
  const resolved = await nextResolve(specifier, context);
  if (specifier !== 'vite' || !/[\\/]vitest[\\/]dist[\\/]/.test(context.parentURL ?? '')) {
    return resolved;
  }
  const separator = resolved.url.includes('?') ? '&' : '?';
  return { ...resolved, url: `${resolved.url}${separator}${SHIM_QUERY}`, shortCircuit: true };
}

export async function load(url, context, nextLoad) {
  const marker = url.lastIndexOf(SHIM_QUERY);
  if (marker === -1 || marker !== url.length - SHIM_QUERY.length) {
    return nextLoad(url, context);
  }
  const real = JSON.stringify(url.slice(0, marker - 1));
  const reporter = JSON.stringify(new URL('./vitest-reporter.mjs', import.meta.url).href);
  return {
    format: 'module',
    shortCircuit: true,
    source: `
import * as vite from ${real};
import { fyoloTestRunsPlugin } from ${reporter};
export * from ${real};
function withPlugin(config) {
  if (!config || typeof config.getSortedPluginHooks === 'function') return config;
  return { ...config, plugins: [...(config.plugins ?? []), fyoloTestRunsPlugin()] };
}
export function resolveConfig(config, ...rest) {
  return vite.resolveConfig(withPlugin(config), ...rest);
}
export function createServer(config = {}, ...rest) {
  return vite.createServer(withPlugin(config), ...rest);
}
`,
  };
}
