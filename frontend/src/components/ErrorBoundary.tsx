import { Component, type ErrorInfo, type ReactNode } from "react";

interface State {
  error: Error | null;
}

/** Shows the error instead of a blank page when a render fails. */
export class ErrorBoundary extends Component<{ children: ReactNode }, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("frontend render error", error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div className="fatal" role="alert">
          <h1>The assistant page hit an error</h1>
          <pre>{this.state.error.message}</pre>
          <button type="button" onClick={() => window.location.reload()}>Reload</button>
        </div>
      );
    }
    return this.props.children;
  }
}
