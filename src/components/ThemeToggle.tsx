import React from 'react';
import { Sun, Moon } from 'lucide-react';

interface ThemeToggleProps {
  theme: 'light' | 'dark';
  onToggle: () => void;
}

export const ThemeToggle: React.FC<ThemeToggleProps> = ({ theme, onToggle }) => {
  return (
    <button
      onClick={onToggle}
      className="p-2 rounded-lg bg-white dark:bg-slate-800 border border-gray-300 dark:border-slate-600 
                 hover:bg-gray-50 dark:hover:bg-slate-700 transition-colors
                 shadow-sm dark:shadow-slate-900/20"
      aria-label="Toggle theme"
    >
      {theme === 'light' ? (
        <Moon className="w-5 h-5 text-gray-700 dark:text-slate-200" />
      ) : (
        <Sun className="w-5 h-5 text-gray-700 dark:text-slate-200" />
      )}
    </button>
  );
};