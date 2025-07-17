import React, { useState, useEffect } from 'react';
import { Homepage } from './components/Homepage';
import { ChatInterface } from './components/ChatInterface';
import { ChatErrorBoundary } from './components/ErrorBoundary';
import { translations, detectLanguage } from './utils/translations';
import { useTheme } from './hooks/useTheme';
import './lib/translation'; // Initialize i18next

type Language = keyof typeof translations;

function App() {
  const [currentView, setCurrentView] = useState<'home' | 'chat'>('home');
  const [language, setLanguage] = useState<Language>(() => detectLanguage());
  const { theme, toggleTheme } = useTheme();

  const handleStartChat = () => {
    setCurrentView('chat');
  };

  const handleBackToHome = () => {
    setCurrentView('home');
  };

  const t = translations[language];

  return (
    <div className="App">
      {currentView === 'home' ? (
        <Homepage
          language={language}
          onLanguageChange={(lang) => setLanguage(lang as Language)}
          translations={t}
          theme={theme}
          onThemeToggle={toggleTheme}
          onStartChat={handleStartChat}
        />
      ) : (
        <ChatErrorBoundary onRetry={handleStartChat}>
          <ChatInterface
            translations={t}
            onBack={handleBackToHome}
            language={language}
          />
        </ChatErrorBoundary>
      )}
    </div>
  );
}

export default App;