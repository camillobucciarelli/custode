# Guida alla compilazione: Déclaration relative à un moyen de cryptologie (ANSSI)

Portale: demarche.numerique.gouv.fr. I valori nella colonna "Valore suggerito"
sono in francese, pronti da incollare. I campi `[DA COMPILARE: ...]` vanno
completati a mano. I nomi esatti dei campi possono differire leggermente da
quelli del modulo: seguire l'ordine delle sezioni.

Allegati obbligatori: `brochure-commerciale.md` e `brochure-technique.md`
(esportare in PDF dopo aver risolto i segnaposto) e l'attestazione firmata
(modello scaricabile dal modulo stesso).

## 1. Bénéficiaire

Selezionare **particulier** (persona fisica).

| Campo | Valore suggerito |
|---|---|
| Type de bénéficiaire | Particulier |
| Nom | [DA COMPILARE: cognome] |
| Prénom | [DA COMPILARE: nome] |
| Adresse | [DA COMPILARE: indirizzo completo in Italia] |
| Pays | Italie |
| Adresse électronique | [DA COMPILARE: e-mail] |
| Téléphone | [DA COMPILARE: telefono con prefisso +39] |

## 2.1 Informations générales

| Campo | Valore suggerito |
|---|---|
| Marque de distribution | Key vault kdbx [DA COMPILARE: confermare il nome esatto su App Store Connect; nel repository il nome visualizzato dell'app e "Custode"] |
| Dénomination | Key vault kdbx [DA COMPILARE: stesso controllo del campo precedente] |
| Version | 0.8.0 |
| Référence commerciale | [DA COMPILARE: Apple ID numerico dell'app o URL della scheda App Store] |
| Date de mise sur le marché | [DA COMPILARE: data di prima pubblicazione sull'App Store in Francia, formato JJ/MM/AAAA] |
| Fabricant (si différent du bénéficiaire) | Identique au bénéficiaire |

## 2.2 Description fonctionnelle

| Campo | Valore suggerito |
|---|---|
| Nature du moyen | Logiciel |
| Description générale et usage prévu | Gestionnaire de mots de passe pour iOS et macOS, distribué gratuitement sur l'Apple App Store. L'application enregistre les identifiants de l'utilisateur (mots de passe, notes, secrets TOTP, clés d'accès) dans un coffre chiffré au format ouvert KeePass .kdbx, stocké dans un fichier local. Elle propose le remplissage automatique des identifiants par l'extension Credential Provider du système et, en option, la synchronisation du fichier déjà chiffré vers le Google Drive personnel de l'utilisateur. Usage prévu : protection des identifiants personnels de l'utilisateur sur son propre appareil. |
| Catégorie de la fonction principale | Sécurité de l'information (gestionnaire de mots de passe, stockage chiffré de données) |

## 2.3 Description technique des services de cryptologie

| Campo | Valore suggerito |
|---|---|
| Cryptologie intégrée et finalité | Le produit n'utilise aucun algorithme propriétaire, uniquement des algorithmes standards publiés, mis en oeuvre par des bibliothèques open source en Dart (kdbx, pointycastle, crypto, otp) et par les interfaces cryptographiques d'Apple (CryptoKit, Security). La cryptologie sert à chiffrer et authentifier le fichier coffre .kdbx de l'utilisateur à partir de son mot de passe maître, à chiffrer les métadonnées locales et le cache de remplissage automatique, à générer les codes TOTP et à signer les assertions WebAuthn des clés d'accès stockées dans le coffre. Les clés sont générées et conservées sur l'appareil ; le développeur n'a accès ni aux données ni aux clés ; il n'existe aucun séquestre de clés. |
| Catégories de services | Authentification, Intégrité, Confidentialité, Signature |
| Authentification | Dérivation de clé depuis le mot de passe maître (Argon2 ou AES-KDF), codes TOTP (RFC 6238), clés d'accès WebAuthn, OAuth 2.0 avec PKCE. |
| Intégrité | SHA-256, HMAC-SHA-256 par bloc du fichier coffre, étiquette d'authentification AES-GCM de 128 bits. |
| Confidentialité | Chiffrement du fichier coffre (AES-256-CBC ou ChaCha20), des métadonnées locales et du cache de remplissage automatique (AES-256-GCM). |
| Signature | ECDSA P-256 avec SHA-256, Ed25519, RSA PKCS#1 v1.5 avec SHA-256, uniquement pour les assertions et enregistrements WebAuthn des clés d'accès. |
| Protocoles sécurisés utilisés | HTTPS/TLS fourni par le système d'exploitation, pour la connexion Google (OAuth 2.0 avec PKCE), l'API Google Drive et la vérification optionnelle des mises à jour. Aucun protocole propre au produit, aucune messagerie chiffrée, aucun VPN. |

## 2.4 Algorithmes cryptographiques

Una voce del modulo per ogni riga.

| Algorithme | Mode | Taille de clé | Utilisation |
|---|---|---|---|
| AES | CBC | 256 bits | Chiffrement du fichier coffre .kdbx |
| ChaCha20 (RFC 7539) | Chiffrement par flux | 256 bits | Chiffrement du fichier coffre .kdbx (KDBX 4) et flux interne des valeurs protégées |
| Salsa20 | Chiffrement par flux | 256 bits | Flux interne des valeurs protégées (KDBX 3.x) |
| Argon2 (Argon2d) | Dérivation de clé | Sortie 256 bits | Dérivation de la clé du coffre depuis le mot de passe maître |
| AES-KDF | ECB, tours itérés, puis SHA-256 | 256 bits | Dérivation de la clé du coffre depuis le mot de passe maître (coffres existants) |
| SHA-256 | Hachage | Sans objet | Intégrité du coffre, dérivation de clés, détection de mots de passe réutilisés, détection de modification de fichier, PKCE S256, WebAuthn |
| SHA-512 | Hachage | Sans objet | Dérivation des clés HMAC du coffre (KDBX 4), Ed25519 |
| HMAC-SHA-256 | MAC | 256 bits | Authentification de l'en-tête et des blocs du fichier coffre (KDBX 4) |
| AES | GCM (nonce 96 bits, étiquette 128 bits) | 256 bits | Chiffrement authentifié des métadonnées locales, du cache de remplissage automatique et des clés d'accès en attente |
| ECDSA P-256 | Signature avec SHA-256 (ES256) | 256 bits | Création et utilisation de clés d'accès (WebAuthn) |
| Ed25519 | Signature EdDSA (RFC 8032) | 256 bits | Utilisation de clés d'accès importées (WebAuthn) |
| RSA | PKCS#1 v1.5 avec SHA-256 (RS256) | [DA COMPILARE: verificare dimensione chiave RSA] | Utilisation de clés d'accès importées (WebAuthn) ; aucune génération de clé RSA |
| HMAC-SHA-1, HMAC-SHA-256, HMAC-SHA-512 | TOTP (RFC 6238) | Longueur du secret fourni par le service tiers | Génération des codes à usage unique |
| MD5 | Hachage | Sans objet | Somme de contrôle pour la détection de modification de fichier (sans rôle de sécurité) |
| Générateur aléatoire du système (CSPRNG) | Sans objet | Sans objet | Génération des clés, nonces, sels et mots de passe |

Nota sulla chiave RSA: il codice non genera chiavi RSA e non impone una
dimensione; firma con la chiave della passkey importata nel vault. Se il modulo
richiede un valore, indicare la dimensione effettivamente supportata dopo
verifica.

## Cosa devi fare personalmente

- [ ] Creare l'account su demarche.numerique.gouv.fr e aprire la procedura
      "Déclaration relative à un moyen de cryptologie".
- [ ] Compilare la sezione 1 con i tuoi dati personali (particulier).
- [ ] Confermare nome dell'app, riferimento commerciale e data di messa sul
      mercato (sezione 2.1) e risolvere tutti i segnaposto `[DA COMPILARE: ...]`
      in questo file e nelle due brochure.
- [ ] Verificare che la versione dichiarata (0.8.0) sia quella effettivamente
      pubblicata o in pubblicazione sull'App Store.
- [ ] Esportare le due brochure in PDF e allegarle.
- [ ] Scaricare il modello di attestazione dal modulo, firmarlo e caricarlo.
- [ ] Inviare la dichiarazione e conservare la ricevuta di deposito.
