import React, { useState, useEffect, useRef } from 'react';
import { Send, SkipForward, ArrowLeft, Loader, Globe, Volume2, MapPin, AlertCircle, Wifi, WifiOff, ArrowRight } from 'lucide-react';
import { useSupabaseChat } from '../hooks/useSupabaseChat';
import { translateText, detectLanguage, SUPPORTED_LANGUAGES } from '../lib/translation';

interface ChatInterfaceProps {
  translations: any;
  onBack: () => void;
  language: string;
}

interface TranslatedMessage {
  id: string;
  senderId: string;
  content: string;
  translatedContent?: string;
  originalLanguage?: string;
  timestamp: number;
  isTranslated?: boolean;
}

export const ChatInterface: React.FC<ChatInterfaceProps> = ({
  translations: t,
  onBack,
  language
}) => {
  const [currentMessage, setCurrentMessage] = useState('');
  const [translatedMessages, setTranslatedMessages] = useState<TranslatedMessage[]>([]);
  const [showTranslations, setShowTranslations] = useState(true);
  const [isTranslating, setIsTranslating] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const {
    currentUser,
    messages,
    isConnecting,
    isConnected,
    partnerId,
    location,
    partnerLocation,
    locationError,
    locationLoading,
    isIPBased,
    connectionError,
    searchAttempts,
    connectionQuality,
    queuePosition,
    estimatedWait,
    waitTime,
    queueStats,
    showNextButton,
    nextButtonCountdown,
    appState,
    startChatWithLocation,
    sendMessage,
    skipPartner,
    handleNextClick,
    handleRetry,
    disconnect,
  } = useSupabaseChat(language);

  // Auto-scroll to bottom
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [translatedMessages]);

  // Process and translate messages
  useEffect(() => {
    const processMessages = async () => {
      if (!messages.length) {
        setTranslatedMessages([]);
        return;
      }

      setIsTranslating(true);
      
      try {
        const processed = await Promise.all(
          messages.map(async (msg) => {
            const originalLang = detectLanguage(msg.content);
            let translatedContent = msg.content;
            let isTranslated = false;

            // Translate if needed and translation is enabled
            if (showTranslations && originalLang !== language && msg.sender_id !== currentUser?.id) {
              try {
                translatedContent = await translateText(msg.content, language, originalLang);
                isTranslated = translatedContent !== msg.content;
              } catch (error) {
                console.warn('Translation failed for message:', error);
              }
            }

            return {
              id: msg.id,
              senderId: msg.sender_id,
              content: msg.content,
              translatedContent: isTranslated ? translatedContent : undefined,
              originalLanguage: originalLang,
              timestamp: new Date(msg.created_at).getTime(),
              isTranslated,
            };
          })
        );

        setTranslatedMessages(processed);
      } catch (error) {
        console.error('Error processing messages:', error);
      } finally {
        setIsTranslating(false);
      }
    };

    processMessages();
  }, [messages, language, showTranslations, currentUser?.id]);

  // Initialize connection on mount
  useEffect(() => {
    if (!currentUser && !isConnecting) {
      console.log('🚀 Auto-starting chat on component mount');
      startChatWithLocation();
    }
  }, [currentUser, isConnecting, startChatWithLocation]);

  const handleSendMessage = async () => {
    if (!currentMessage.trim() || !isConnected) return;

    await sendMessage(currentMessage);
    setCurrentMessage('');
  };

  const handleKeyPress = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
    }
  };

  const handleBack = () => {
    disconnect();
    onBack();
  };

  const speakMessage = (text: string, lang?: string) => {
    if ('speechSynthesis' in window) {
      const utterance = new SpeechSynthesisUtterance(text);
      if (lang) {
        utterance.lang = lang;
      }
      speechSynthesis.speak(utterance);
    }
  };


  // Show loading/search/error screens
  if (appState.phase !== 'idle' && appState.phase !== 'connected' && !isConnected) {
    return (
      <div className="h-screen bg-slate-50 dark:bg-slate-900 flex items-center justify-center">
        <div className="text-center p-8 bg-white dark:bg-slate-800 rounded-2xl shadow-xl max-w-md mx-4">
          
          {/* Error State */}
          {appState.phase === 'error' && (
            <>
              <div className="w-16 h-16 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
                <AlertCircle className="w-8 h-8 text-red-500 animate-pulse" />
              </div>
              <h2 className="text-xl font-semibold text-red-600 dark:text-red-400 mb-2">
                Erreur de connexion
              </h2>
              <p className="text-gray-600 dark:text-slate-300 mb-4">
                {appState.message}
              </p>
              {appState.details && (
                <p className="text-xs text-gray-500 dark:text-slate-400 mb-4">
                  {appState.details}
                </p>
              )}
              {appState.canRetry && (
                <button
                  onClick={handleRetry}
                  className="px-6 py-3 bg-blue-500 text-white rounded-lg hover:bg-blue-600 
                             transition-colors shadow-md mb-4"
                >
                  Réessayer
                </button>
              )}
              <button
                onClick={handleBack}
                className="block mx-auto text-gray-600 dark:text-slate-300 hover:text-blue-500 
                           transition-colors text-sm"
              >
                Retour à l'accueil
              </button>
            </>
          )}
          
          {/* Loading/Search States */}
          {appState.phase !== 'error' && (
            <>
          <div className="w-16 h-16 bg-blue-100 dark:bg-blue-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
                {(appState.phase === 'loading' || appState.phase === 'geolocation') && <MapPin className="w-8 h-8 text-blue-500 animate-pulse" />}
                {(appState.phase === 'joining_queue' || appState.phase === 'searching') && <Loader className="w-8 h-8 text-blue-500 animate-spin" />}
                {appState.phase === 'matching' && <Globe className="w-8 h-8 text-green-500 animate-pulse" />}
                {appState.phase === 'confirming' && <Wifi className="w-8 h-8 text-yellow-500 animate-pulse" />}
          </div>
          
          <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
                {appState.phase === 'loading' && 'Chargement...'}
                {appState.phase === 'geolocation' && 'Localisation'}
                {appState.phase === 'joining_queue' && 'Connexion en cours'}
                {appState.phase === 'searching' && 'Recherche de partenaire'}
                {appState.phase === 'matching' && 'Partenaire trouvé !'}
                {appState.phase === 'confirming' && 'Confirmation de connexion'}
          </h2>
          
          <p className="text-gray-600 dark:text-slate-300 mb-4">
                {appState.message}
          </p>
          
              {appState.details && (
            <p className="text-sm text-gray-500 dark:text-slate-400 mb-4">
                  {appState.details}
            </p>
              )}
          
          {/* Enhanced dynamic progress indicators */}
          <div className="mb-4">
                {(appState.phase === 'loading' || appState.phase === 'geolocation' || appState.phase === 'joining_queue') && (
              <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-3 mb-2">
                <div className="bg-blue-500 h-3 rounded-full transition-all duration-1000" 
                     style={{ 
                           width: appState.phase === 'geolocation' ? '30%' : 
                                  appState.phase === 'loading' ? '60%' : 
                                  appState.phase === 'joining_queue' ? '90%' : '100%',
                       animation: 'pulse 2s ease-in-out infinite'
                     }}>
                </div>
              </div>
            )}
                {appState.phase === 'searching' && (
              <div className="flex items-center justify-center gap-1 mb-2">
                <div className="w-2 h-2 bg-blue-500 rounded-full animate-bounce" style={{ animationDelay: '0ms' }}></div>
                <div className="w-2 h-2 bg-blue-500 rounded-full animate-bounce" style={{ animationDelay: '150ms' }}></div>
                <div className="w-2 h-2 bg-blue-500 rounded-full animate-bounce" style={{ animationDelay: '300ms' }}></div>
              </div>
            )}
                {appState.phase === 'confirming' && (
              <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2 mb-2">
                <div className="bg-yellow-500 h-2 rounded-full animate-pulse" style={{ width: '75%' }}></div>
              </div>
            )}
          </div>
          
          {/* Progress indicators */}
              {appState.phase === 'searching' && (
            <div className="space-y-2">
              {/* Timer display */}
              {waitTime > 0 && (
                <div className="text-lg text-blue-600 dark:text-blue-400 font-mono font-bold">
                  <div className="inline-flex items-center gap-2">
                    <div className="w-2 h-2 bg-blue-500 rounded-full animate-pulse"></div>
                    {Math.floor(waitTime / 60)}:{(waitTime % 60).toString().padStart(2, '0')}
                  </div>
                </div>
              )}
              
              {/* Queue position */}
              {queuePosition !== null && (
                <p className="text-sm text-blue-600 dark:text-blue-400 font-semibold">
                  Position in queue: #{queuePosition + 1}
                </p>
              )}
              
              {queueStats && (
                <div className="text-xs text-gray-500 dark:text-slate-400 space-y-1">
                  <p>{queueStats.total_waiting} users online</p>
                  {searchAttempts > 0 && <p>Search attempt: {searchAttempts}</p>}
                  {connectionQuality < 100 && (
                    <p>Connection quality: {connectionQuality}%</p>
                  )}
                </div>
              )}
              
              {/* Encouraging message for long waits */}
              {waitTime > 30 && (
                <p className="text-xs text-green-600 dark:text-green-400 animate-pulse">
                  🌟 Hang tight! We're finding the perfect match for you...
                </p>
              )}
              
              {/* Auto-retry message */}
              {waitTime > 60 && (
                <p className="text-xs text-yellow-600 dark:text-yellow-400">
                  🌍 Expanding search globally for better matches...
                </p>
              )}
            </div>
          )}
              </>
            )}
          
          <button
            onClick={handleBack}
                className="mt-6 px-4 py-2 text-gray-600 dark:text-slate-300 hover:text-blue-500 
                       transition-colors text-sm"
          >
                Annuler
          </button>
        </div>
      </div>
    );
  }
  
  return (
    <div className="h-screen bg-slate-50 dark:bg-slate-900 flex flex-col">
      {/* Header */}
      <div className="bg-white dark:bg-slate-800 border-b border-gray-200 dark:border-slate-700 px-4 py-3
                     shadow-sm dark:shadow-slate-900/20">
        <div className="flex items-center justify-between">
          <button
            onClick={handleBack}
            className="flex items-center gap-2 text-gray-600 dark:text-slate-300 hover:text-blue-500 
                       transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
            <span className="hidden sm:inline">Back</span>
          </button>
          
          <div className="flex items-center gap-4">
            {/* Partner Location Info */}
            {partnerLocation && (
              <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-slate-400 bg-gray-100 dark:bg-slate-700 px-3 py-1 rounded-full">
                <MapPin className="w-4 h-4" />
                <span className="text-xs">
                  Partner: {partnerLocation.city || 'Unknown'}, {partnerLocation.country || 'Unknown'}
                </span>
              </div>
            )}

            {/* Connection Status */}
            <div className="flex items-center gap-2">
              {connectionError && (
                <div className="flex items-center gap-2 text-red-500">
                  <AlertCircle className="w-4 h-4" />
                  <span className="text-sm">Connection Error</span>
                </div>
              )}
              {isConnecting && (
                <div className="flex items-center gap-2 text-yellow-500">
                  <Loader className="w-4 h-4 animate-spin" />
                  <span className="text-sm">
                        {appState.message || t.chat.connecting}
                        {searchAttempts > 0 && ` (Tentative ${searchAttempts})`}
                  </span>
                </div>
              )}
              {isConnected && (
                <div className="flex items-center gap-2 text-green-500">
                  <Wifi className="w-4 h-4" />
                  <span className="text-sm">{t.chat.connected}</span>
                </div>
              )}
              {!isConnecting && !isConnected && (
                <div className="flex items-center gap-2 text-red-500">
                  <WifiOff className="w-4 h-4" />
                  <span className="text-sm">{t.chat.disconnected}</span>
                </div>
              )}
            </div>

            {/* Translation Toggle */}
            <button
              onClick={() => setShowTranslations(!showTranslations)}
              className={`flex items-center gap-2 px-3 py-2 rounded-lg transition-colors ${
                showTranslations
                  ? 'bg-blue-500 text-white'
                  : 'bg-gray-200 dark:bg-slate-700 text-gray-700 dark:text-slate-300'
              }`}
            >
              <Globe className="w-4 h-4" />
              <span className="hidden sm:inline">
                {showTranslations ? 'Auto-translate ON' : 'Auto-translate OFF'}
              </span>
            </button>
          </div>
          
          <button
            onClick={skipPartner}
            disabled={!isConnected}
            className="flex items-center gap-2 px-3 py-2 bg-blue-500 text-white rounded-lg 
                       dark:bg-blue-600 hover:bg-blue-600 dark:hover:bg-blue-500
                       disabled:opacity-50 disabled:cursor-not-allowed 
                       transition-colors shadow-md dark:shadow-blue-500/20"
          >
            <SkipForward className="w-4 h-4" />
            <span className="hidden sm:inline">{t.chat.skip}</span>
          </button>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {/* Connection Error */}
        {connectionError && (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 
                         rounded-lg p-3 text-red-800 dark:text-red-200 text-sm">
            <div className="flex items-center gap-2">
              <AlertCircle className="w-4 h-4" />
              <span>{connectionError}</span>
            </div>
          </div>
        )}

        {/* Location Error */}
        {locationError && (
          <div className={`border rounded-lg p-3 text-sm ${
            isIPBased 
              ? 'bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800 text-blue-800 dark:text-blue-200'
              : 'bg-yellow-50 dark:bg-yellow-900/20 border-yellow-200 dark:border-yellow-800 text-yellow-800 dark:text-yellow-200'
          }`}>
            <div className="flex items-center gap-2">
              <MapPin className="w-4 h-4" />
              <span>{locationError}</span>
            </div>
          </div>
        )}

        {/* Connection Status Info */}
        {isConnecting && (
          <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 
                         rounded-lg p-3 text-blue-800 dark:text-blue-200 text-sm">
            <div className="flex items-center gap-2">
              <Loader className="w-4 h-4 animate-spin" />
              <span>
                    {appState.message || 'Connexion...'}
                {waitTime > 0 && ` (${Math.floor(waitTime / 60)}:${(waitTime % 60).toString().padStart(2, '0')})`}
                {searchAttempts > 0 && ` - Attempt ${searchAttempts}`}
                {queueStats && ` - ${queueStats.total_waiting} users waiting`}
              </span>
            </div>
            {waitTime > 45 && (
              <div className="mt-2 text-xs opacity-75">
                    Recherche en cours... Nous allons trouver quelqu'un de parfait pour vous !
              </div>
            )}
            {queuePosition !== null && estimatedWait && (
              <div className="mt-2 text-xs opacity-75">
                    Position dans la file : {queuePosition + 1} • Attente estimée : {Math.round(estimatedWait)}s
              </div>
            )}
          </div>
        )}

        {/* Queue Statistics */}
        {isConnecting && queueStats && (
          <div className="bg-gray-50 dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 
                         rounded-lg p-3 text-gray-600 dark:text-gray-300 text-xs">
            <div className="flex items-center justify-between">
              <span>Queue: {queueStats.total_waiting} waiting</span>
              <span>Quality: {connectionQuality}%</span>
            </div>
            <div className="flex items-center justify-between mt-1">
              {queueStats.by_continent && (
                <span>
                  {Object.entries(queueStats.by_continent).map(([continent, count]) => (
                    <span key={continent} className="ml-2">
                      {continent}: {count}
                    </span>
                  ))}
                </span>
              )}
              {searchAttempts > 0 && <span>Attempts: {searchAttempts}</span>}
            </div>
          </div>
        )}

        {translatedMessages.map((message) => {
          const isOwnMessage = message.senderId === currentUser?.id;
          const isSystemMessage = message.senderId === 'system';
          const displayText = message.isTranslated && showTranslations 
            ? message.translatedContent 
            : message.content;

          // System messages (like disconnection notices)
          if (isSystemMessage) {
            return (
              <div key={message.id} className="flex justify-center">
                <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 
                               rounded-lg px-4 py-2 text-red-800 dark:text-red-200 text-sm">
                  <div className="flex items-center gap-2">
                    <AlertCircle className="w-4 h-4" />
                    <span>{displayText}</span>
                  </div>
                </div>
              </div>
            );
          }
          return (
            <div
              key={message.id}
              className={`flex ${isOwnMessage ? 'justify-end' : 'justify-start'}`}
            >
              <div
                className={`max-w-xs lg:max-w-md px-4 py-2 rounded-2xl relative group ${
                  isOwnMessage
                    ? 'bg-blue-500 text-white'
                    : 'bg-white dark:bg-slate-800 text-gray-900 dark:text-slate-100 border border-gray-200 dark:border-slate-700'
                }`}
              >
                <div className="flex items-start gap-2">
                  <div className="flex-1">
                    <p className="text-sm">{displayText}</p>
                    
                    {/* Show original text if translated */}
                    {message.isTranslated && showTranslations && (
                      <p className="text-xs opacity-70 mt-1 italic border-t border-gray-300 dark:border-slate-600 pt-1">
                        Original: {message.content}
                      </p>
                    )}
                    
                    <div className="flex items-center justify-between mt-1">
                      <p className="text-xs opacity-70">
                        {new Date(message.timestamp).toLocaleTimeString()}
                      </p>
                      
                      {/* Language indicator */}
                      {message.originalLanguage && message.originalLanguage !== language && (
                        <span className="text-xs opacity-60 ml-2">
                          {SUPPORTED_LANGUAGES[message.originalLanguage as keyof typeof SUPPORTED_LANGUAGES] || message.originalLanguage}
                        </span>
                      )}
                    </div>
                  </div>
                  
                  {/* Text-to-speech button */}
                  <button
                    onClick={() => speakMessage(displayText || message.content, message.originalLanguage)}
                    className="opacity-0 group-hover:opacity-100 transition-opacity p-1 hover:bg-gray-200 dark:hover:bg-slate-700 rounded"
                  >
                    <Volume2 className="w-3 h-3" />
                  </button>
                </div>
              </div>
            </div>
          );
        })}
        
        {isTranslating && (
          <div className="flex justify-center">
            <div className="flex items-center gap-2 text-blue-500">
              <Loader className="w-4 h-4 animate-spin" />
              <span className="text-sm">Translating...</span>
            </div>
          </div>
        )}
        
        <div ref={messagesEndRef} />
      </div>

      {/* Next Button Overlay */}
      {showNextButton && (
        <div className="absolute inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-white dark:bg-slate-800 rounded-2xl p-6 text-center shadow-2xl max-w-sm mx-4">
            <div className="w-16 h-16 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
              <AlertCircle className="w-8 h-8 text-red-500" />
            </div>
            <h3 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              User Disconnected
            </h3>
            <p className="text-gray-600 dark:text-slate-300 mb-6">
              Your chat partner has left the conversation.
            </p>
            <button
              onClick={handleNextClick}
              className="w-full flex items-center justify-center gap-2 px-6 py-3 bg-blue-500 text-white rounded-lg 
                         hover:bg-blue-600 transition-colors shadow-md"
            >
              <ArrowRight className="w-5 h-5" />
              {nextButtonCountdown > 0 ? (
                <span>Next Chat ({nextButtonCountdown}s)</span>
              ) : (
                <span>Find Next Partner</span>
              )}
            </button>
          </div>
        </div>
      )}

      {/* Input */}
      <div className="bg-white dark:bg-slate-800 border-t border-gray-200 dark:border-slate-700 p-4
                     shadow-lg dark:shadow-slate-900/20">
        <div className="flex gap-2">
          <input
            type="text"
            value={currentMessage}
            onChange={(e) => setCurrentMessage(e.target.value)}
            onKeyPress={handleKeyPress}
            placeholder={t.chat.typeMessage}
            disabled={!isConnected}
            className="flex-1 px-4 py-2 border border-gray-300 dark:border-slate-600 rounded-lg 
                       bg-gray-50 dark:bg-slate-700 text-gray-900 dark:text-slate-100 
                       placeholder-gray-500 dark:placeholder-slate-400
                       focus:outline-none focus:ring-2 focus:ring-blue-500 
                       disabled:opacity-50 disabled:cursor-not-allowed"
          />
          <button
            onClick={handleSendMessage}
            disabled={!currentMessage.trim() || !isConnected}
            className="px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 
                       dark:bg-blue-600 dark:hover:bg-blue-500
                       disabled:opacity-50 disabled:cursor-not-allowed transition-colors
                       shadow-md dark:shadow-blue-500/20"
          >
            <Send className="w-5 h-5" />
          </button>
        </div>
        
        {/* Connection info */}
        <div className="mt-2 flex items-center justify-between text-xs text-gray-500 dark:text-slate-400">
          {/* Your location */}
          {location && (
            <div className="flex items-center gap-1">
              <MapPin className="w-3 h-3" />
              <span>
                You: {location.city}, {location.country}
                {isIPBased && <span className="text-orange-500 ml-1">(IP-based)</span>}
              </span>
            </div>
          )}
          
          {/* Language */}
          <div className="flex items-center gap-1">
            <span>🌐 {SUPPORTED_LANGUAGES[language as keyof typeof SUPPORTED_LANGUAGES]}</span>
          </div>
        </div>
      </div>
    </div>
  );
};