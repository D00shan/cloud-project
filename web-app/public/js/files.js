const list = document.querySelector("#files-list");
const message = document.querySelector("#files-message");
const refreshButton = document.querySelector("#refresh-button");
let refreshInProgress = false;
let pollInterval = 5000;
let pollTimer;

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
}

function fileCard(file) {
  const article = document.createElement("article");
  article.className = "file-card";

  const information = document.createElement("div");
  const name = document.createElement("h2");
  name.className = "file-name";
  name.textContent = file.originalName;
  const details = document.createElement("p");
  details.className = "file-details";

  const status = document.createElement("span");
  status.className = `status status-${file.status}`;
  status.textContent = file.status;
  const date = document.createElement("time");
  date.dateTime = file.uploadedAt;
  date.textContent = new Date(file.uploadedAt).toLocaleString();
  details.append(status, date);
  if (file.compressedSize !== null) {
    const size = document.createElement("span");
    size.textContent = `Compressed: ${formatBytes(file.compressedSize)}`;
    details.append(size);
  }
  information.append(name, details);
  article.append(information);

  if (file.status === "ready") {
    const download = document.createElement("button");
    download.type = "button";
    download.className = "secondary-button";
    download.textContent = "Download .gz";
    download.addEventListener("click", () => downloadFile(file, download));
    article.append(download);
  }
  return article;
}

async function downloadFile(file, button) {
  button.disabled = true;
  button.textContent = "Preparing…";
  try {
    const response = await fetch("/api/files/download-url", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ compressedKey: file.compressedKey }),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(result.error || "The download could not be prepared.");
    }
    window.location.assign(result.url);
  } catch (error) {
    message.textContent = error.message;
    message.className = "message error";
  } finally {
    button.disabled = false;
    button.textContent = "Download .gz";
  }
}

async function refreshFiles() {
  if (refreshInProgress) return;
  refreshInProgress = true;
  refreshButton.disabled = true;
  message.textContent = list.children.length
    ? "Refreshing…"
    : "Loading recent files…";
  message.className = "message";

  try {
    const response = await fetch("/api/files");
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(result.error || "Recent files could not be loaded.");
    }

    list.replaceChildren(...result.files.map(fileCard));
    if (Number.isInteger(result.pollIntervalMs) && result.pollIntervalMs >= 1000) {
      pollInterval = result.pollIntervalMs;
    }
    message.textContent = result.files.length
      ? `Showing ${result.files.length} recent upload${result.files.length === 1 ? "" : "s"}.`
      : "No uploads yet. Choose Upload to compress your first file.";
  } catch (error) {
    message.textContent = `${error.message} You can try Refresh again.`;
    message.className = "message error";
  } finally {
    refreshInProgress = false;
    refreshButton.disabled = false;
    window.clearTimeout(pollTimer);
    pollTimer = window.setTimeout(refreshFiles, pollInterval);
  }
}

refreshButton.addEventListener("click", refreshFiles);
refreshFiles();
