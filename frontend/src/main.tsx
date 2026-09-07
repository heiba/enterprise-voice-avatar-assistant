import React from "react";
import { createRoot } from "react-dom/client";
import { LogLevel, setLogLevel } from "livekit-client";
import App from "./App";
import "@livekit/components-styles";
import "./styles.css";

// Open the page with ?debug=1 to get verbose LiveKit client logs (ICE candidates, TURN, reconnects).
if (new URLSearchParams(window.location.search).has("debug")) setLogLevel(LogLevel.debug);

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
