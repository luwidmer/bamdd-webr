// Deploy-time configuration. tools/make-dist.sh rewrites this file in dist/ when the
// filesystem image is served from somewhere other than the page itself (see DEPLOY.md).

// Resolved against the page URL, so a relative value keeps the offline layout working.
export const LIBRARY_IMAGE_URL = 'lib/library.tar.gz';
