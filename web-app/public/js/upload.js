const form = document.querySelector("#upload-form");
const input = document.querySelector("#file-input");
const selection = document.querySelector("#selection");
const button = document.querySelector("#upload-button");
const message = document.querySelector("#message");

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
}

input.addEventListener("change", () => {
  const file = input.files[0];
  selection.textContent = file
    ? `${file.name} · ${formatBytes(file.size)}`
    : "No file selected";
  message.textContent = "";
  message.className = "message";
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (button.disabled) return;

  const file = input.files[0];
  if (!file) {
    message.textContent = "Choose a file before uploading.";
    message.className = "message error";
    return;
  }

  button.disabled = true;
  input.disabled = true;
  button.textContent = "Uploading…";
  message.textContent = "Securely uploading your file…";
  message.className = "message";

  try {
    const body = new FormData();
    body.append("file", file);
    const response = await fetch("/api/uploads", { method: "POST", body });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(result.error || "The upload could not be completed.");
    }

    message.replaceChildren(
      document.createTextNode(
        `${result.originalName} was uploaded successfully. Compression continues in the background. `,
      ),
      Object.assign(document.createElement("a"), {
        href: "/files.html",
        textContent: "View recent files",
      }),
    );
    message.className = "message success";
    form.reset();
    selection.textContent = "No file selected";
  } catch (error) {
    message.textContent = error.message;
    message.className = "message error";
  } finally {
    button.disabled = false;
    input.disabled = false;
    button.textContent = "Upload for compression";
  }
});
