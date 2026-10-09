import type { MetadataRoute } from "next";

// /colors is excluded via a noindex meta tag (its layout) rather than a crawl
// disallow, so search engines can actually see the noindex.
export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: "*", allow: "/" },
    sitemap: "https://www.fyolo.sh/sitemap.xml",
  };
}
