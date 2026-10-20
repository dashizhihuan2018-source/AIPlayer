const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: {
    desktop: {
      postMessage: (message) => {
        if (!message || typeof message.id !== "string") return;
        ipcRenderer
          .invoke("native", message)
          .then((result) =>
            window.dispatchEvent(
              new CustomEvent("aiplayer:native", {
                detail: { id: message.id, result },
              }),
            ),
          )
          .catch((error) =>
            window.dispatchEvent(
              new CustomEvent("aiplayer:native", {
                detail: { id: message.id, error: error.message },
              }),
            ),
          );
      },
    },
  },
});
ipcRenderer.on("native-event", (_e, detail) =>
  window.dispatchEvent(new CustomEvent("aiplayer:native", { detail })),
);
