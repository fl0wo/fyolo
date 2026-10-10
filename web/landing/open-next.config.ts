import { defineCloudflareConfig } from "@opennextjs/cloudflare";
import staticAssetsIncrementalCache from "@opennextjs/cloudflare/overrides/incremental-cache/static-assets-incremental-cache";

// The site is fully prerendered and never revalidates on the server, so its
// pages are served straight from the build output in Workers static assets.
// Without a cache the Worker re-renders each request, and the docs pages — which
// read their own .mdx source while rendering — fail: a Worker has no
// filesystem to read content/docs from.
export default defineCloudflareConfig({
	incrementalCache: staticAssetsIncrementalCache,
});
