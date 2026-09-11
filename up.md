Phase 0 : à préparer sur ta machine (avant de toucher aux serveurs)
Acheter le domaine (meenerva.io ou autre) chez un registrar avec API DNS. Recommandé : Cloudflare (utile plus tard pour l'ACME DNS-01 de Stalwart).
Créer les comptes tiers :
Backblaze B2 : un bucket meenerva-backups + une Application Key (keyID + applicationKey).
Un fournisseur mail transactionnel pour le relais sortant (Amazon SES, Postmark, MailerSend ou Brevo). Récupère host/port/user/password SMTP et le include: SPF.
Créer le repo GitHub privé meenerva-infra et y pousser le dépôt local :

cd /Users/macbookpro/MeenervaProjects/meenerva-infra
git commit -m "Initial infrastructure scaffold"
git remote add origin git@github.com:<org>/meenerva-infra.git
git push -u origin main
Le .gitignore protège déjà les .env. Rien de secret ne part.
Noter les deux IP : core-node = V6, apps-node = V8 (IPv4 et IPv6 si dispo).
Générer tous les secrets en avance dans un gestionnaire de mots de passe (Bitwarden/1Password) : une valeur par ligne CHANGE_ME des deux .env.example. Commande : openssl rand -base64 36.
Phase 1 : core-node (serveur V6)
Prérequis en main : IP du V6, accès root SSH, secrets générés.

DNS (à faire maintenant, la propagation prend du temps). Publier au minimum, d'après docs/05-dns-and-mail.md :
A (et AAAA) : meenerva.io, traefik, portainer, id, mail, n8n, webmail vers l'IP du V6
CNAME : autoconfig, autodiscover vers mail.meenerva.io
MX : meenerva.io vers 10 mail.meenerva.io
TXT SPF : v=spf1 mx a:mail.meenerva.io include:<relais> -all
TXT DMARC sur _dmarc : v=DMARC1; p=quarantine; rua=mailto:dmarc@meenerva.io
Le DKIM sera ajouté à l'étape 12 (généré par Stalwart)
PTR / rDNS : dans le panel Contabo, régler le reverse DNS de l'IP du V6 sur mail.meenerva.io. Étape critique pour la délivrabilité.
Vérifier la résolution : dig +short id.meenerva.io doit renvoyer l'IP du V6 avant l'étape 10 (sinon l'ACME échoue).
Préparer le serveur :

ssh root@<ip-v6>
git clone https://github.com/<org>/meenerva-infra.git /opt/meenerva-infra
cd /opt/meenerva-infra
./scripts/bootstrap-node.sh      # Docker, UFW, fail2ban, swap 4G, WireGuard tools
./scripts/init-core-node.sh      # ouvre 80/443 + ports mail, crée les réseaux Docker
Remplir les secrets :

cp core-node/.env.example core-node/.env
nano core-node/.env
Remplir : PRIMARY_DOMAIN, ACME_EMAIL, TRAEFIK_DASHBOARD_AUTH (via htpasswd -nbB), tous les *_PASSWORD et *_KEY/*_SECRET, les B2_*, RESTIC_PASSWORD. Laisser SMTP_RELAY_* vide pour l'instant, WEBMAIL_OAUTH_ENABLED=false.
Lancer la stack core :

make core-config      # validation
make core-up          # Traefik, Portainer, Postgres, Redis, Keycloak, Stalwart, Bulwark, n8n, backups
make core-logs        # attendre "Certificate obtained" de Traefik
Les bases app_keycloak et app_n8n sont créées automatiquement au premier boot de Postgres (car les mots de passe sont dans .env).
Phase 2 : configuration initiale du core
Stalwart (https://mail.meenerva.io, login admin / STALWART_FALLBACK_ADMIN_SECRET) :
Domains > ajouter meenerva.io
Copier l'enregistrement DKIM affiché et le publier en DNS (<selector>._domainkey)
Accounts > créer admin@, no-reply@, puis une boîte par personne (prenom.nom@)
Settings > SMTP > Outbound > configurer le relais avec les identifiants du fournisseur transactionnel (ou remplir SMTP_RELAY_* dans .env et make core-up)
Reporter le mot de passe de no-reply@ dans core-node/.env :
N8N_SMTP_PASSWORD=... et (pour plus tard, apps-node) MAIL_FROM_PASSWORD=...
make core-up pour appliquer
Portainer (https://portainer.meenerva.io) : créer le compte admin dans les 5 minutes suivant le premier démarrage.
Traefik (https://traefik.meenerva.io, login = TRAEFIK_DASHBOARD_AUTH) : vérifier que tous les routers sont verts.
Keycloak (https://id.meenerva.io, login admin / KEYCLOAK_ADMIN_PASSWORD) :
Créer le realm meenerva
Realm settings > Email : SMTP host core-stalwart, port 587, StartTLS, from no-reply@meenerva.io, auth avec la boîte no-reply@
Authentication : activer une policy MFA (OTP requis)
Clients > créer webmail (confidential, valid redirect https://webmail.meenerva.io/*), copier le secret
Activer le SSO Bulwark : dans core-node/.env, WEBMAIL_OAUTH_ENABLED=true + WEBMAIL_OAUTH_CLIENT_SECRET=<secret>, puis make core-up.
Bulwark Webmail (https://webmail.meenerva.io) : se connecter via Keycloak, vérifier l'accès à une boîte.
n8n (https://n8n.meenerva.io) : créer le compte owner, vérifier l'envoi d'un mail de test.
Phase 3 : validation de la messagerie
Depuis Bulwark, envoyer un message à https://www.mail-tester.com et viser 10/10. Corriger SPF/DKIM/DMARC/PTR selon le rapport.
Envoyer un mail vers une adresse Gmail et une Outlook, vérifier qu'il arrive en boîte de réception (pas en spam).
Tester la réception : envoyer depuis l'extérieur vers admin@meenerva.io.
Phase 4 : sauvegardes
Vérifier que B2_* et RESTIC_PASSWORD sont bien dans core-node/.env (sinon make core-up).
Lancer une sauvegarde manuelle :

./scripts/backup-now.sh core
Vérifier dans le bucket B2 la présence de core-node/meenerva-core-<date>.tar.gz.
Test de restauration (sur un VPS jetable, plus tard mais avant de dépendre du système) : ./scripts/restore.sh list puis full.
Phase 5 : core-node en GitOps (Portainer)
Dans Portainer > Stacks > Add stack > Repository :
URL du repo, référence refs/heads/main, chemin core-node/docker-compose.yml
Charger les variables d'environnement (mêmes valeurs que core-node/.env)
Activer "Automatic updates" (polling 5 min) ou le webhook
À partir de là : git push sur main redéploie le core automatiquement.
Phase 6 : apps-node (serveur V8)
Prérequis : Phase 1 à 3 stables.

DNS : A/AAAA pour cloud, office (et plus tard chat, project, erp, sign) vers l'IP du V8. Option wildcard * A <ip-v8>.
Préparer le serveur :

ssh root@<ip-v8>
git clone https://github.com/<org>/meenerva-infra.git /opt/meenerva-infra
cd /opt/meenerva-infra
./scripts/bootstrap-node.sh
./scripts/init-apps-node.sh
Monter le tunnel WireGuard (détail dans docs/04-networking-wireguard.md) :

# sur le V6
./scripts/setup-wireguard.sh core          # note la clé publique affichée
# sur le V8
./scripts/setup-wireguard.sh apps           # colle la clé publique + l'IP du V6
# sur le V6
./scripts/setup-wireguard.sh add-peer apps <clé-pub-v8> <ip-publique-v8>
# test depuis le V8
ping -c3 10.10.0.1
Vérifier l'accès aux services partagés depuis le V8 :

nc -zv 10.10.0.1 5432 && nc -zv 10.10.0.1 6379
Configurer et lancer la stack edge du V8 :

cp apps-node/.env.example apps-node/.env
nano apps-node/.env       # PRIMARY_DOMAIN, ACME_EMAIL, TRAEFIK_DASHBOARD_AUTH,
                          # CORE_REDIS_PASSWORD, MAIL_FROM_PASSWORD, B2_*, RESTIC_PASSWORD
make apps-config && make apps-up
Enregistrer l'agent Portainer du V8 : Portainer (sur le V6) > Environments > Add > Agent, adresse 10.10.0.2:9001.
Phase 7 : première application, Nextcloud + Nextcloud Mail
Créer la base (sur le V6) :

./scripts/create-app-database.sh nextcloud
Reporter le mot de passe affiché dans l'env du stack Nextcloud.
Client Keycloak : créer nextcloud (confidential, redirect https://cloud.meenerva.io/apps/user_oidc/code).
Déployer via Portainer > Stacks > Repository > apps-node/apps/nextcloud/docker-compose.yml, env d'après apps-node/apps/nextcloud/.env.example.
https://cloud.meenerva.io : terminer l'installation admin, installer l'app OpenID Connect user backend (pointer sur le realm meenerva), régler Collabora sur https://office.meenerva.io.
Nextcloud Mail : occ app:install mail, appliquer le bloc provisioning_settings de apps-node/apps/nextcloud/README.md (IMAP/SMTP vers mail.meenerva.io:993/587). Chaque utilisateur crée un mot de passe d'application dans Stalwart.
Ajouter nextcloud-data et nextcloud-html à la liste des volumes de offsite-backup dans apps-node/docker-compose.yml, puis ./scripts/backup-now.sh apps et vérifier le bucket.
Phase 8 : à partir de là
Chaque nouvel outil : make app-new NAME=<x> puis suivre docs/08-adding-an-app.md (base, client Keycloak, DNS, déploiement Portainer, docs à jour).
Suivre l'ordre des phases de docs/09-roadmap.md.
Mettre en place un monitoring léger (Uptime Kuma sur le V6 ou le V8) tôt.
Planifier le test de restauration trimestriel.
Chemin critique minimal pour "avoir la messagerie qui tourne" : étapes 6 à 22. Le reste peut suivre à ton rythme.