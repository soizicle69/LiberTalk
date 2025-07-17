import React, { Component, ReactNode } from 'react';
import { AlertCircle, RefreshCw } from 'lucide-react';

interface Props {
  children: ReactNode;
  fallback?: (error: Error, retry: () => void) => ReactNode;
  onError?: (error: Error, errorInfo: any) => void;
}

interface State {
  hasError: boolean;
  error: Error | null;
  errorInfo: any;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      errorInfo: null
    };
  }

  static getDerivedStateFromError(error: Error): State {
    console.error('🚨 ErrorBoundary caught error:', error);
    return {
      hasError: true,
      error,
      errorInfo: null
    };
  }

  componentDidCatch(error: Error, errorInfo: any) {
    console.error('🚨 ErrorBoundary componentDidCatch:', error, errorInfo);
    this.setState({
      error,
      errorInfo
    });
    
    // Call onError callback if provided
    this.props.onError?.(error, errorInfo);
  }

  handleRetry = () => {
    console.log('🔄 ErrorBoundary retry triggered');
    this.setState({
      hasError: false,
      error: null,
      errorInfo: null
    });
  };

  render() {
    if (this.state.hasError) {
      // Use custom fallback if provided
      if (this.props.fallback) {
        return this.props.fallback(this.state.error!, this.handleRetry);
      }

      // Default error UI
      return (
        <div className="min-h-screen bg-slate-50 dark:bg-slate-900 flex items-center justify-center p-4">
          <div className="bg-white dark:bg-slate-800 rounded-2xl shadow-xl p-8 max-w-md w-full text-center">
            <div className="w-16 h-16 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
              <AlertCircle className="w-8 h-8 text-red-500" />
            </div>
            
            <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              Application Error
            </h2>
            
            <p className="text-gray-600 dark:text-slate-300 mb-4">
              {this.state.error?.message || 'Something went wrong'}
            </p>
            
            {process.env.NODE_ENV === 'development' && this.state.errorInfo && (
              <details className="text-left text-xs text-gray-500 dark:text-slate-400 mb-4 bg-gray-50 dark:bg-slate-700 p-3 rounded">
                <summary className="cursor-pointer font-medium">Error Details</summary>
                <pre className="mt-2 whitespace-pre-wrap">
                  {this.state.error?.stack}
                </pre>
              </details>
            )}
            
            <button
              onClick={this.handleRetry}
              className="flex items-center justify-center gap-2 w-full px-6 py-3 bg-blue-500 text-white rounded-lg 
                         hover:bg-blue-600 transition-colors shadow-md"
            >
              <RefreshCw className="w-5 h-5" />
              Retry
            </button>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

// Chat-specific ErrorBoundary
interface ChatErrorBoundaryProps {
  children: ReactNode;
  onRetry: () => void;
}

export const ChatErrorBoundary: React.FC<ChatErrorBoundaryProps> = ({ children, onRetry }) => {
  return (
    <ErrorBoundary
      fallback={(error, retry) => (
        <div className="min-h-screen bg-slate-50 dark:bg-slate-900 flex items-center justify-center p-4">
          <div className="bg-white dark:bg-slate-800 rounded-2xl shadow-xl p-8 max-w-md w-full text-center">
            <div className="w-16 h-16 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
              <AlertCircle className="w-8 h-8 text-red-500" />
            </div>
            
            <h2 className="text-xl font-semibold text-red-600 dark:text-red-400 mb-2">
              Chat Error
            </h2>
            
            <p className="text-gray-600 dark:text-slate-300 mb-6">
              {error.message || 'Chat initialization failed'}
            </p>
            
            <div className="space-y-3">
              <button
                onClick={() => {
                  retry();
                  onRetry();
                }}
                className="flex items-center justify-center gap-2 w-full px-6 py-3 bg-blue-500 text-white rounded-lg 
                           hover:bg-blue-600 transition-colors shadow-md"
              >
                <RefreshCw className="w-5 h-5" />
                Retry Chat
              </button>
              
              <button
                onClick={() => window.location.reload()}
                className="w-full px-6 py-3 text-gray-600 dark:text-slate-300 hover:text-blue-500 
                           transition-colors text-sm"
              >
                Reload Page
              </button>
            </div>
          </div>
        </div>
      )}
      onError={(error, errorInfo) => {
        console.error('🚨 Chat ErrorBoundary:', error, errorInfo);
        // Could send to error reporting service here
      }}
    >
      {children}
    </ErrorBoundary>
  );
};