const releaseEndpoint = "https://api.github.com/repos/shivamx96/gitacre/releases/tags/v1.0.0-beta";
const releasesEnabled = true;

const previews = {
  repositories: {
    src: "assets/screenshots/gitacre-pending.png",
    alt: "gitacre showing repositories with uncommitted, ahead-of-remote, and stashed work",
    title: "Unfinished work, surfaced.",
    description: "See every repository that needs attention without opening a terminal."
  },
  worktrees: {
    src: "assets/screenshots/gitacre-worktrees.png",
    alt: "gitacre showing a repository expanded to reveal its linked worktrees",
    title: "Worktrees stay together.",
    description: "Keep linked checkouts beneath their repository, with branch context intact."
  },
  prs: {
    src: "assets/screenshots/gitacre-prs.png",
    alt: "gitacre showing open pull requests and review requests",
    title: "Reviews beside the work.",
    description: "See your open pull requests and review requests through the GitHub CLI session you already use."
  }
};

const previewImage = document.querySelector("#preview-image");
const previewTitle = document.querySelector("#preview-title");
const previewDescription = document.querySelector("#preview-description");
const previewPanel = document.querySelector(".preview-window");
const previewTabs = [...document.querySelectorAll("[data-preview]")];

function selectPreview(key, moveFocus = false) {
  const preview = previews[key];
  const activeTab = previewTabs.find((tab) => tab.dataset.preview === key);
  if (!preview || !activeTab || activeTab.getAttribute("aria-selected") === "true") return;

  previewTabs.forEach((tab) => {
    const selected = tab === activeTab;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });

  previewPanel.setAttribute("aria-labelledby", activeTab.id);
  previewImage.classList.add("is-changing");

  window.setTimeout(() => {
    previewImage.src = preview.src;
    previewImage.alt = preview.alt;
    previewTitle.textContent = preview.title;
    previewDescription.textContent = preview.description;
    previewImage.classList.remove("is-changing");
  }, 140);

  if (moveFocus) activeTab.focus();
}

previewTabs.forEach((tab, index) => {
  tab.tabIndex = tab.getAttribute("aria-selected") === "true" ? 0 : -1;
  tab.addEventListener("click", () => selectPreview(tab.dataset.preview));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();

    let nextIndex = index;
    if (event.key === "ArrowLeft") nextIndex = (index - 1 + previewTabs.length) % previewTabs.length;
    if (event.key === "ArrowRight") nextIndex = (index + 1) % previewTabs.length;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = previewTabs.length - 1;

    selectPreview(previewTabs[nextIndex].dataset.preview, true);
  });
});

function enableRelease(release) {
  const diskImage = release.assets?.find((asset) => asset.name.toLowerCase().endsWith(".dmg"));
  const downloadURL = diskImage?.browser_download_url || release.html_url;
  const version = release.tag_name?.replace(/^v/, "") || release.name;

  document.querySelectorAll(".release-link, #download-button").forEach((link) => {
    link.href = downloadURL;
    link.classList.remove("is-unavailable");
    link.removeAttribute("aria-disabled");
    const label = link.querySelector("span");
    if (label) label.textContent = "Download for macOS";
    else link.textContent = link.classList.contains("nav-download") ? "Download" : "Download for macOS";
  });

  const note = document.querySelector("#release-note");
  if (note) note.textContent = `${version} · macOS 14+ · Apple silicon + Intel`;
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

const year = document.querySelector("#year");
if (year) year.textContent = new Date().getFullYear();
