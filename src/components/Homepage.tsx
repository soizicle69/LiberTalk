import React from 'react';
import { MessageCircle, Shield, Zap, Globe, Play } from 'lucide-react';
import { RotatingGlobe } from './RotatingGlobe';
import { LanguageSelector } from './LanguageSelector';
import { ThemeToggle } from './ThemeToggle';

interface HomepageProps {
  language: string;
  onLanguageChange: (lang: string) => void;
  translations: any;
  theme: 'light' | 'dark';
  onThemeToggle: () => void;
  onStartChat: () => void;
}

export const Homepage: React.FC<HomepageProps> = ({
  language,
  onLanguageChange,
  translations: t,
  theme,
  onThemeToggle,
  onStartChat
}) => {
  const features = [
    {
      icon: Shield,
      title: t.features.anonymous,
      description: 'No registration required. Complete privacy guaranteed.'
    },
    {
      icon: Zap,
      title: t.features.instant,
      description: 'Connect with someone new in seconds.'
    },
    {
      icon: Globe,
      title: t.features.global,
      description: 'Chat with people from around the world.'
    }
  ];

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-50 via-blue-50 to-indigo-100 
                    dark:from-slate-900 dark:via-gray-900 dark:to-indigo-950 relative overflow-hidden">
      <RotatingGlobe />
      
      {/* Header */}
      <header className="relative z-10 flex justify-between items-center p-6">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-gradient-to-r from-blue-500 to-purple-500 rounded-xl flex items-center justify-center
                         shadow-lg shadow-blue-500/25 dark:shadow-blue-400/40">
            <MessageCircle className="w-6 h-6 text-white" />
          </div>
          <h1 className="text-2xl font-bold bg-gradient-to-r from-blue-600 to-purple-600 
                         dark:from-blue-400 dark:to-purple-400 bg-clip-text text-transparent">
            {t.title}
          </h1>
        </div>
        
        <div className="flex items-center gap-3">
          <LanguageSelector currentLanguage={language} onLanguageChange={onLanguageChange} />
          <ThemeToggle theme={theme} onToggle={onThemeToggle} />
        </div>
      </header>

      {/* Main Content */}
      <main className="relative z-10 flex flex-col items-center justify-center px-6 py-20">
        <div className="text-center max-w-4xl mx-auto">
          <h2 className="text-4xl md:text-6xl font-bold text-gray-900 dark:text-slate-100 mb-6 
                         leading-tight">
            {t.slogan}
          </h2>
          
          <p className="text-xl text-gray-600 dark:text-slate-300 mb-12 max-w-2xl mx-auto">
            {t.description}
          </p>
          
          <button
            onClick={onStartChat}
            className="group relative inline-flex items-center gap-3 px-8 py-4 text-lg font-semibold 
                       text-white bg-gradient-to-r from-blue-500 to-purple-500 
                       dark:from-blue-600 dark:to-purple-600 rounded-2xl 
                       hover:from-blue-600 hover:to-purple-600 dark:hover:from-blue-500 dark:hover:to-purple-500
                       transition-all duration-300 transform hover:scale-105 
                       shadow-xl shadow-blue-500/25 dark:shadow-blue-400/40 
                       hover:shadow-2xl hover:shadow-blue-500/40 dark:hover:shadow-blue-400/60"
          >
            <Play className="w-6 h-6 transition-transform group-hover:scale-110" />
            {t.startChat}
            <div className="absolute -top-1 -right-1 w-3 h-3 bg-green-400 rounded-full animate-pulse" />
            <div className="absolute inset-0 rounded-2xl bg-gradient-to-r from-blue-400 to-purple-400
                           dark:from-blue-300 dark:to-purple-300 opacity-0 group-hover:opacity-20 
                           transition-opacity duration-300" />
          </button>
          
          <p className="text-sm text-gray-500 dark:text-slate-400 mt-4 max-w-md mx-auto">
            📍 We'll request your location to find nearby people. You can refuse and we'll use IP location instead.
          </p>
        </div>

        {/* Features Grid */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8 max-w-4xl mx-auto mt-20">
          {features.map((feature, index) => {
            const Icon = feature.icon;
            return (
              <div key={index} className="text-center p-6 bg-white/80 dark:bg-gray-800/80 
                                         dark:bg-slate-800/90 backdrop-blur-sm rounded-2xl 
                                         border border-gray-200 dark:border-slate-700 
                                         hover:shadow-xl dark:hover:shadow-2xl dark:hover:shadow-blue-500/20
                                         transition-all duration-300">
                <div className="w-12 h-12 bg-gradient-to-r from-blue-500 to-purple-500
                               rounded-xl flex items-center justify-center mx-auto mb-4">
                  <Icon className="w-6 h-6 text-white" />
                </div>
                <h3 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
                  {feature.title}
                </h3>
                <p className="text-gray-600 dark:text-slate-300">
                  {feature.description}
                </p>
              </div>
            );
          })}
        </div>
      </main>

      {/* Footer */}
      <footer className="relative z-10 text-center p-6 text-gray-500 dark:text-slate-400">
        <p>© 2024 LiberTalk. Made with ❤️ for global connections.</p>
      </footer>
    </div>
  );
};