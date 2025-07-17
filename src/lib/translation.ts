import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import LanguageDetector from 'i18next-browser-languagedetector';

// Simple translation service using LibreTranslate API (free)
const LIBRE_TRANSLATE_API = 'https://libretranslate.de/translate';

// Initialize i18next
i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    fallbackLng: 'en',
    debug: false,
    interpolation: {
      escapeValue: false,
    },
    resources: {
      en: {
        translation: {
          // Existing translations...
        }
      },
      fr: {
        translation: {
          // Existing translations...
        }
      },
      // Add more languages as needed
    }
  });

// Language detection and mapping
const SUPPORTED_LANGUAGES = {
  'en': 'English',
  'fr': 'Français',
  'de': 'Deutsch',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'ru': 'Русский',
  'zh': '中文',
  'ja': '日本語',
  'ko': '한국어',
  'ar': 'العربية',
};

// Detect language from text (simple heuristic)
export const detectLanguage = (text: string): string => {
  // Simple language detection based on character patterns
  if (/[\u4e00-\u9fff]/.test(text)) return 'zh'; // Chinese
  if (/[\u3040-\u309f\u30a0-\u30ff]/.test(text)) return 'ja'; // Japanese
  if (/[\uac00-\ud7af]/.test(text)) return 'ko'; // Korean
  if (/[\u0600-\u06ff]/.test(text)) return 'ar'; // Arabic
  if (/[\u0400-\u04ff]/.test(text)) return 'ru'; // Russian
  
  // European language detection (basic)
  const commonWords = {
    'fr': ['le', 'la', 'les', 'de', 'et', 'à', 'un', 'une', 'ce', 'que', 'qui', 'dans', 'pour', 'avec'],
    'de': ['der', 'die', 'das', 'und', 'in', 'zu', 'den', 'von', 'mit', 'ist', 'auf', 'für', 'als', 'sich'],
    'es': ['el', 'la', 'de', 'que', 'y', 'a', 'en', 'un', 'es', 'se', 'no', 'te', 'lo', 'le'],
    'it': ['il', 'di', 'che', 'e', 'la', 'per', 'un', 'in', 'con', 'non', 'da', 'su', 'del', 'al'],
    'pt': ['o', 'de', 'a', 'e', 'que', 'do', 'da', 'em', 'um', 'para', 'é', 'com', 'não', 'uma'],
  };

  const words = text.toLowerCase().split(/\s+/);
  let maxScore = 0;
  let detectedLang = 'en';

  Object.entries(commonWords).forEach(([lang, commonWordsList]) => {
    const score = words.filter(word => commonWordsList.includes(word)).length;
    if (score > maxScore) {
      maxScore = score;
      detectedLang = lang;
    }
  });

  return detectedLang;
};

// Translate text using LibreTranslate
export const translateText = async (
  text: string,
  targetLang: string,
  sourceLang?: string
): Promise<string> => {
  try {
    // Auto-detect source language if not provided
    const source = sourceLang || detectLanguage(text);
    
    // Don't translate if source and target are the same
    if (source === targetLang) return text;

    const response = await fetch(LIBRE_TRANSLATE_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        q: text,
        source,
        target: targetLang,
        format: 'text',
      }),
    });

    if (!response.ok) {
      throw new Error(`Translation failed: ${response.statusText}`);
    }

    const data = await response.json();
    return data.translatedText || text;
  } catch (error) {
    console.warn('Translation failed, returning original text:', error);
    return text;
  }
};

// Batch translate multiple texts
export const translateTexts = async (
  texts: string[],
  targetLang: string,
  sourceLang?: string
): Promise<string[]> => {
  try {
    const translations = await Promise.all(
      texts.map(text => translateText(text, targetLang, sourceLang))
    );
    return translations;
  } catch (error) {
    console.warn('Batch translation failed:', error);
    return texts; // Return original texts on failure
  }
};

export { SUPPORTED_LANGUAGES };
export default i18n;