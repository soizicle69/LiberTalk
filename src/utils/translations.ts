export const translations = {
  en: {
    title: 'LiberTalk',
    slogan: 'Anonymous Random Chat: Connect with the World in One Click!',
    startChat: 'Start Chat',
    description: 'Connect instantly with people from around the world. Anonymous, secure, and free.',
    features: {
      anonymous: 'Completely Anonymous',
      instant: 'Instant Matching',
      secure: 'Secure & Private',
      global: 'Global Community'
    },
    chat: {
      connecting: 'Connecting...',
      connected: 'Connected! Start chatting...',
      disconnected: 'Partner disconnected',
      skip: 'Skip Partner',
      next: 'Next Chat',
      typeMessage: 'Type a message...',
      send: 'Send'
    },
    errors: {
      connection: 'Connection error. Please try again.',
      matching: 'No partners available. Please try again later.'
    }
  },
  fr: {
    title: 'LiberTalk',
    slogan: 'Chat Aléatoire Anonyme : Connectez-vous au Monde en Un Clic !',
    startChat: 'Commencer le Chat',
    description: 'Connectez-vous instantanément avec des personnes du monde entier. Anonyme, sécurisé et gratuit.',
    features: {
      anonymous: 'Complètement Anonyme',
      instant: 'Matching Instantané',
      secure: 'Sécurisé et Privé',
      global: 'Communauté Mondiale'
    },
    chat: {
      connecting: 'Connexion...',
      connected: 'Connecté ! Commencez à chatter...',
      disconnected: 'Partenaire déconnecté',
      skip: 'Passer au Suivant',
      next: 'Chat Suivant',
      typeMessage: 'Tapez un message...',
      send: 'Envoyer'
    },
    errors: {
      connection: 'Erreur de connexion. Veuillez réessayer.',
      matching: 'Aucun partenaire disponible. Veuillez réessayer plus tard.'
    }
  },
  de: {
    title: 'LiberTalk',
    slogan: 'Anonymer Zufalls-Chat: Verbinden Sie sich mit der Welt in einem Klick!',
    startChat: 'Chat Starten',
    description: 'Verbinden Sie sich sofort mit Menschen aus der ganzen Welt. Anonym, sicher und kostenlos.',
    features: {
      anonymous: 'Vollständig Anonym',
      instant: 'Sofortiges Matching',
      secure: 'Sicher & Privat',
      global: 'Globale Gemeinschaft'
    },
    chat: {
      connecting: 'Verbindung...',
      connected: 'Verbunden! Beginnen Sie zu chatten...',
      disconnected: 'Partner getrennt',
      skip: 'Partner Überspringen',
      next: 'Nächster Chat',
      typeMessage: 'Nachricht eingeben...',
      send: 'Senden'
    },
    errors: {
      connection: 'Verbindungsfehler. Bitte versuchen Sie es erneut.',
      matching: 'Keine Partner verfügbar. Bitte versuchen Sie es später erneut.'
    }
  },
  es: {
    title: 'LiberTalk',
    slogan: 'Chat Aleatorio Anónimo: ¡Conéctate con el Mundo en Un Clic!',
    startChat: 'Iniciar Chat',
    description: 'Conéctate instantáneamente con personas de todo el mundo. Anónimo, seguro y gratis.',
    features: {
      anonymous: 'Completamente Anónimo',
      instant: 'Matching Instantáneo',
      secure: 'Seguro y Privado',
      global: 'Comunidad Global'
    },
    chat: {
      connecting: 'Conectando...',
      connected: '¡Conectado! Comienza a chatear...',
      disconnected: 'Compañero desconectado',
      skip: 'Saltar Compañero',
      next: 'Siguiente Chat',
      typeMessage: 'Escribe un mensaje...',
      send: 'Enviar'
    },
    errors: {
      connection: 'Error de conexión. Por favor, inténtalo de nuevo.',
      matching: 'No hay compañeros disponibles. Por favor, inténtalo más tarde.'
    }
  },
  it: {
    title: 'LiberTalk',
    slogan: 'Chat Casuale Anonima: Connettiti con il Mondo in Un Click!',
    startChat: 'Inizia Chat',
    description: 'Connettiti istantaneamente con persone di tutto il mondo. Anonimo, sicuro e gratuito.',
    features: {
      anonymous: 'Completamente Anonimo',
      instant: 'Matching Istantaneo',
      secure: 'Sicuro e Privato',
      global: 'Comunità Globale'
    },
    chat: {
      connecting: 'Connessione...',
      connected: 'Connesso! Inizia a chattare...',
      disconnected: 'Partner disconnesso',
      skip: 'Salta Partner',
      next: 'Chat Successiva',
      typeMessage: 'Digita un messaggio...',
      send: 'Invia'
    },
    errors: {
      connection: 'Errore di connessione. Riprova.',
      matching: 'Nessun partner disponibile. Riprova più tardi.'
    }
  }
};

export const detectLanguage = (): keyof typeof translations => {
  const browserLang = navigator.language.toLowerCase();
  const langCode = browserLang.split('-')[0];
  
  if (langCode in translations) {
    return langCode as keyof typeof translations;
  }
  
  return 'en';
};