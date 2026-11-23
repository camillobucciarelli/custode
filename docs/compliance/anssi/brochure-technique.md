# Brochure technique du moyen de cryptologie

Document joint à la déclaration relative à un moyen de cryptologie (ANSSI).

## 1. Identification du produit

| Élément | Valeur |
|---|---|
| Marque de distribution (App Store) | Key vault kdbx [DA COMPILARE: confermare il nome esatto su App Store Connect; nel repository il nome visualizzato dell'app e "Custode"] |
| Type | Logiciel uniquement (application mobile et de bureau) |
| Version | 0.8.0 (build 105) |
| Plateformes déclarées | iOS 18.0 ou ultérieur, macOS 14.0 ou ultérieur |
| Distribution | Apple App Store, gratuit |
| Éditeur / fabricant | [DA COMPILARE: nome e cognome dello sviluppatore, persona fisica] |
| Contact | [DA COMPILARE: indirizzo e-mail di contatto] |
| Date de mise sur le marché | [DA COMPILARE: data di prima pubblicazione sull'App Store] |

## 2. Description fonctionnelle

Le produit est un gestionnaire de mots de passe. Il enregistre les identifiants
de l'utilisateur (noms d'utilisateur, mots de passe, notes, secrets TOTP, clés
d'accès « passkeys ») dans un coffre chiffré au format ouvert KeePass `.kdbx`,
stocké dans un fichier local choisi par l'utilisateur.

Fonctions principales :

- création, ouverture et déverrouillage d'un coffre `.kdbx` par mot de passe
  maître, avec déverrouillage biométrique optionnel ;
- consultation et modification des entrées, générateur de mots de passe,
  affichage des codes TOTP ;
- remplissage automatique des identifiants et utilisation des clés d'accès par
  l'extension « Credential Provider » d'iOS et de macOS ;
- synchronisation optionnelle, désactivée par défaut, du fichier `.kdbx` chiffré
  vers le Google Drive personnel de l'utilisateur ;
- contrôle de l'état du coffre (détection des mots de passe réutilisés).

Le produit ne fournit ni messagerie, ni VPN, ni chiffrement de communications
entre utilisateurs. La cryptologie sert exclusivement à protéger les données de
l'utilisateur stockées sur son appareil et à authentifier l'utilisateur auprès
de services tiers (TOTP, clés d'accès).

## 3. Architecture et emplacement de la cryptologie

L'application est développée avec Flutter (langage Dart) et comporte, sur iOS et
macOS, une extension native Swift « Credential Provider ».

| Composant | Rôle | Cryptologie appliquée |
|---|---|---|
| Fichier coffre `.kdbx` | Stockage des identifiants | Chiffrement et authentification du fichier (format KDBX 3.1 et 4), dérivation de clé depuis le mot de passe maître |
| Métadonnées de l'application | Fichiers de métadonnées locaux | Chiffrement authentifié AES-256-GCM |
| Extension Credential Provider (iOS, macOS) | Cache des identifiants pour le remplissage automatique, enregistrements de clés d'accès en attente | Chiffrement authentifié AES-256-GCM (Apple CryptoKit) |
| Clés d'accès (passkeys) | Authentification WebAuthn auprès de sites tiers | Signature numérique ECDSA P-256, Ed25519, RSA PKCS#1 v1.5 ; génération de paires de clés ECDSA P-256 |
| Codes TOTP | Authentification à deux facteurs | HMAC (RFC 6238) |
| Trousseau Apple (Keychain) | Stockage des clés et secrets locaux | Protection assurée par le système d'exploitation |
| Synchronisation Google Drive | Transfert du fichier `.kdbx` déjà chiffré | TLS fourni par le système d'exploitation |

Aucun algorithme propriétaire n'est utilisé. Tous les algorithmes sont des
standards publiés. Aucune bibliothèque cryptographique native n'est embarquée :
la cryptologie est réalisée en Dart par des bibliothèques open source et par les
interfaces cryptographiques du système Apple (CryptoKit, Security).

## 4. Services de cryptologie fournis

### 4.1 Confidentialité

- Chiffrement du fichier coffre : AES-256 en mode CBC ou ChaCha20 (RFC 7539),
  selon l'en-tête du fichier. Les coffres créés par l'application utilisent
  KDBX 4 avec AES-256-CBC.
- Protection des valeurs sensibles à l'intérieur du coffre (flux interne) :
  Salsa20 (KDBX 3.x) ou ChaCha20 (KDBX 4).
- Chiffrement des métadonnées locales de l'application : AES-256-GCM.
- Chiffrement du cache de remplissage automatique et des clés d'accès en
  attente dans l'extension : AES-256-GCM.

### 4.2 Intégrité

- Fichier coffre : SHA-256 (empreinte de l'en-tête et des blocs), HMAC-SHA-256
  par bloc avec clés dérivées par SHA-512 (KDBX 4).
- Métadonnées et cache : étiquette d'authentification GCM de 128 bits.
- Détection de modification de fichier et comparaison avec la copie distante :
  empreintes SHA-256 et MD5 (somme de contrôle fournie par l'API Google Drive),
  sans rôle de sécurité.

### 4.3 Authentification

- Authentification de l'utilisateur pour l'ouverture du coffre : dérivation de
  clé depuis le mot de passe maître par Argon2 (variante Argon2d, sortie de
  256 bits) ou AES-KDF (tours AES-256 suivis de SHA-256).
- Codes TOTP (RFC 6238) : HMAC-SHA-1, HMAC-SHA-256 ou HMAC-SHA-512, selon le
  paramètre de l'URI `otpauth`.
- Clés d'accès (WebAuthn) : assertion signée avec la clé privée stockée dans le
  coffre.
- OAuth 2.0 avec PKCE (méthode S256, SHA-256) pour la connexion à Google.

### 4.4 Signature

- ECDSA sur la courbe P-256 avec SHA-256 (ES256).
- Ed25519 (EdDSA, RFC 8032).
- RSA PKCS#1 v1.5 avec SHA-256 (RS256), uniquement avec des clés importées.

Les signatures servent uniquement aux assertions et aux enregistrements
WebAuthn des clés d'accès de l'utilisateur. Le produit ne signe pas de documents.

## 5. Algorithmes cryptographiques

| Algorithme | Mode | Taille de clé | Usage | Bibliothèque / implémentation |
|---|---|---|---|---|
| AES | CBC | 256 bits | Chiffrement du fichier coffre `.kdbx` | `kdbx`, `pointycastle` |
| ChaCha20 (RFC 7539) | Flux | 256 bits | Chiffrement du fichier coffre `.kdbx` (KDBX 4), flux interne des valeurs protégées (KDBX 4) | `kdbx`, `pointycastle` |
| Salsa20 | Flux | 256 bits | Flux interne des valeurs protégées (KDBX 3.x) | `kdbx`, `pointycastle` |
| Argon2 (Argon2d) | Dérivation de clé | Sortie 256 bits | Dérivation de la clé du coffre depuis le mot de passe maître | `kdbx`, `pointycastle` (Dart) |
| AES-KDF | ECB, tours itérés, puis SHA-256 | 256 bits | Dérivation de la clé du coffre depuis le mot de passe maître (coffres existants) | `kdbx`, `pointycastle` |
| SHA-256 | Hachage | Sans objet | Intégrité du coffre, dérivation de clés KDBX, détection de mots de passe réutilisés, détection de modification, PKCE S256, WebAuthn | `kdbx`, `crypto`, `pointycastle`, Apple CryptoKit |
| SHA-512 | Hachage | Sans objet | Dérivation des clés HMAC du coffre (KDBX 4), Ed25519 | `kdbx`, `crypto` |
| HMAC-SHA-256 | MAC | 256 bits (clé de bloc dérivée par SHA-512) | Authentification de l'en-tête et des blocs du coffre (KDBX 4) | `kdbx`, `crypto` |
| AES | GCM, nonce aléatoire de 96 bits, étiquette de 128 bits | 256 bits | Chiffrement authentifié des métadonnées locales de l'application | `pointycastle` |
| AES | GCM | 256 bits | Chiffrement authentifié du cache de remplissage automatique et des clés d'accès en attente (extension iOS/macOS) | Apple CryptoKit |
| ECDSA P-256 | Signature avec SHA-256 (ES256), génération de paires de clés | 256 bits | Création et utilisation de clés d'accès (WebAuthn) | Apple CryptoKit (extension), `pointycastle` |
| Ed25519 | Signature EdDSA (RFC 8032) | 256 bits | Utilisation de clés d'accès importées (WebAuthn) | Apple CryptoKit (extension), implémentation Dart du standard avec SHA-512 de `crypto` |
| RSA | PKCS#1 v1.5 avec SHA-256 (RS256) | [DA COMPILARE: verificare dimensione chiave RSA] (clé importée, taille non imposée par le code ; aucune génération de clé RSA) | Utilisation de clés d'accès importées (WebAuthn) | Apple Security (extension), `pointycastle` |
| HMAC-SHA-1, HMAC-SHA-256, HMAC-SHA-512 | TOTP (RFC 6238) | Longueur du secret fourni par le service tiers | Génération des codes à usage unique | `otp` |
| MD5 | Hachage | Sans objet | Somme de contrôle pour la détection de modification de fichier et la comparaison avec Google Drive (sans rôle de sécurité) | `crypto` |
| Générateur aléatoire | CSPRNG du système | Sans objet | Génération des clés, nonces, sels et mots de passe | `Random.secure` (Dart), `SecRandomCopyBytes` (Apple) |

## 6. Gestion des clés

- Clé du coffre : dérivée du mot de passe maître saisi par l'utilisateur
  (Argon2 ou AES-KDF). Elle n'existe qu'en mémoire pendant que le coffre est
  déverrouillé.
- Mot de passe maître : jamais transmis hors de l'appareil. Il n'est enregistré
  dans le trousseau Apple (Keychain) que si l'utilisateur active le
  déverrouillage biométrique pour ce coffre, et il est supprimé à la
  désactivation.
- Clé de chiffrement des métadonnées : 256 bits, générée aléatoirement sur
  l'appareil, stockée dans le trousseau Apple via `flutter_secure_storage`.
- Clés de l'extension Credential Provider : générées par `SecRandomCopyBytes`,
  stockées dans le trousseau Apple avec l'attribut
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Clés privées des clés d'accès : stockées dans le coffre `.kdbx` chiffré.
- Jetons OAuth Google : stockés dans le trousseau Apple, uniquement si la
  synchronisation est activée.
- Aucune clé ne quitte l'appareil. Le développeur n'a accès ni aux données ni
  aux clés des utilisateurs. Il n'existe aucun séquestre de clés, aucun
  mécanisme de recouvrement et aucune porte dérobée.

## 7. Protocoles

- HTTPS/TLS, exclusivement par la pile réseau du système d'exploitation, pour
  la connexion Google (OAuth 2.0 avec PKCE) et l'API Google Drive, uniquement
  si l'utilisateur active la synchronisation.
- HTTPS/TLS pour la vérification optionnelle des mises à jour (une requête GET
  vers un fichier statique, désactivée par défaut).
- Aucun protocole de sécurité propre au produit, aucune messagerie chiffrée de
  bout en bout, aucun VPN.
- Le fichier synchronisé est le fichier `.kdbx` déjà chiffré localement ; le
  fournisseur de stockage ne reçoit ni le mot de passe maître ni le contenu
  déchiffré.

## 8. Bibliothèques tierces

| Bibliothèque | Version | Licence | Rôle |
|---|---|---|---|
| `kdbx` | 2.6.0 | GPL-3.0 | Lecture et écriture du format KDBX |
| `pointycastle` | 4.0.0 | MIT | Primitives cryptographiques en Dart |
| `crypto` | 3.0.8 | BSD 3-Clause | Fonctions de hachage et HMAC |
| `otp` | 3.2.1 | MIT | Codes TOTP |
| `flutter_secure_storage` | 10.3.4 | BSD 3-Clause | Accès au trousseau Apple |
| Apple CryptoKit, Apple Security | Fournis par iOS et macOS | Sans objet | AES-GCM, signatures, aléa, trousseau |
