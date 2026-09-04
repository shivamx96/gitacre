const releaseEndpoint = "https://api.github.com/repos/shivamx96/gitacre/releases/latest";
const releasesEnabled = false;

function enableRelease(release) {
  const diskImage = release.assets?.find((asset) => asset.name.toLowerCase().endsWith(".dmg"));
  const downloadURL = diskImage?.browser_download_url || release.html_url;
  const version = release.name || release.tag_name;

  document.querySelectorAll(".release-link, #download-button").forEach((link) => {
    link.href = downloadURL;
    link.classList.remove("is-unavailable");
    link.removeAttribute("aria-disabled");
    const label = link.querySelector("span");
    if (label) label.textContent = "Download for macOS";
    else link.textContent = "Download for macOS";
  });

  const note = document.querySelector("#release-note");
  if (note) note.textContent = `${version} · Native app for macOS 14 and later`;
}

document.querySelectorAll("[aria-disabled='true']").forEach((link) => {
  link.addEventListener("click", (event) => event.preventDefault());
});

if (releasesEnabled) {
  fetch(releaseEndpoint, { headers: { Accept: "application/vnd.github+json" } })
    .then((response) => response.ok ? response.json() : Promise.reject())
    .then(enableRelease)
    .catch(() => {});
}

document.querySelector("#year").textContent = new Date().getFullYear();
