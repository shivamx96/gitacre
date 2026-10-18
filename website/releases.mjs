const prefix = 'https://github.com/shivamx96/gitacre/releases/download/';

// A prerelease is eligible, but drafts and local test artifacts never are.
export function selectRelease(releases) {
  if (!Array.isArray(releases)) return null;
  const candidates = releases.filter(release => release && !release.draft)
    .sort((a, b) => (Date.parse(b.published_at) || 0) - (Date.parse(a.published_at) || 0));
  for (const release of candidates) {
    const asset = Array.isArray(release.assets) && release.assets.find(asset => asset &&
      /^gitacre-.*\.dmg$/.test(asset.name) && !asset.name.endsWith('-local.dmg') &&
      typeof asset.browser_download_url === 'string' && asset.browser_download_url.startsWith(prefix));
    if (asset) return { url: asset.browser_download_url, version: release.tag_name || release.name || 'Release', prerelease: !!release.prerelease };
  }
  return null;
}
