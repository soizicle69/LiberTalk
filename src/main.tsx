import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.tsx';
import { ErrorBoundary } from './components/ErrorBoundary';
import './index.css';

try {
  console.log('🚀 Initializing React app...');
  
  const rootElement = document.getElementById('root');
  if (!rootElement) {
    throw new Error('Root element not found in DOM');
  }
  
  console.log('✅ Root element found, creating React root...');
  
  const root = createRoot(rootElement);
  
  root.render(
    <StrictMode>
      <ErrorBoundary
        onError={(error, errorInfo) => {
          console.error('🚨 Global error caught:', error, errorInfo);
          // Could send to error reporting service here
        }}
      >
        <App />
      </ErrorBoundary>
    </StrictMode>
  );
  
  console.log('✅ React app initialized successfully');
  
} catch (error) {
  console.error('🚨 Fatal error initializing React app:', error);
  
  // Fallback error display
  document.body.innerHTML = `
    <div style="
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      background: #f8fafc;
      font-family: system-ui, sans-serif;
      padding: 20px;
    ">
      <div style="
        background: white;
        padding: 40px;
        border-radius: 12px;
        box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        text-align: center;
        max-width: 400px;
      ">
        <div style="
          width: 60px;
          height: 60px;
          background: #fee2e2;
          border-radius: 50%;
          display: flex;
          align-items: center;
          justify-content: center;
          margin: 0 auto 20px;
          font-size: 24px;
        ">⚠️</div>
        <h2 style="color: #dc2626; margin-bottom: 16px;">Application Failed to Load</h2>
        <p style="color: #6b7280; margin-bottom: 24px;">
          ${error instanceof Error ? error.message : 'Unknown initialization error'}
        </p>
        <button 
          onclick="window.location.reload()" 
          style="
            background: #3b82f6;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
          "
        >
          Reload Page
        </button>
      </div>
    </div>
  `;
}
