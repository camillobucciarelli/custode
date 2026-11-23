# Key vault kdbx

[DA COMPILARE: confermare il nome esatto su App Store Connect; nel repository il nome visualizzato dell'app e "Custode"]

Gestionnaire de mots de passe pour iPhone, iPad et Mac, compatible avec le
format ouvert KeePass `.kdbx`.

## Présentation

Key vault kdbx conserve vos identifiants dans un coffre chiffré, enregistré
dans un fichier `.kdbx` que vous gardez sur votre appareil. Le coffre s'ouvre
avec votre mot de passe maître. Le fichier reste lisible par KeePass et les
applications compatibles.

## Fonctionnalités

- Création et ouverture de coffres au format KeePass `.kdbx`.
- Déverrouillage par mot de passe maître, avec déverrouillage biométrique
  optionnel.
- Gestion des entrées : identifiants, mots de passe, notes.
- Générateur de mots de passe.
- Codes de validation à usage unique (TOTP).
- Remplissage automatique des identifiants dans les applications et les sites
  web, par l'intégration au système iOS et macOS.
- Prise en charge des clés d'accès (passkeys) enregistrées dans le coffre.
- Synchronisation optionnelle du fichier chiffré avec votre propre Google
  Drive, désactivée par défaut.
- Contrôle de l'état du coffre : détection des mots de passe réutilisés.

## Plateformes

iOS 18.0 ou ultérieur et macOS 14.0 ou ultérieur.

## Prix et distribution

Application gratuite, distribuée sur l'Apple App Store.

## Sécurité

Le coffre est chiffré sur l'appareil avec des algorithmes standards publiés
(AES-256 ou ChaCha20), à partir d'une clé dérivée de votre mot de passe maître.
Le mot de passe maître et les clés ne quittent jamais l'appareil : l'éditeur
n'a accès ni à vos données ni à vos clés, et ne peut pas les récupérer. Si la
synchronisation est activée, seul le fichier déjà chiffré est envoyé vers votre
Google Drive.

L'application ne crée aucun compte et ne collecte aucune donnée.

## Éditeur et contact

- Éditeur : [DA COMPILARE: nome e cognome dello sviluppatore, persona fisica]
- Contact : [DA COMPILARE: indirizzo e-mail di contatto]
- Page App Store : [DA COMPILARE: URL della scheda App Store]
