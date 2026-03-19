# Oracle Database Password Management

Scripts per la gestione delle password degli utenti Oracle con integrazione HashiCorp Vault.

## Overview

Questa directory contiene script per la gestione completa delle credenziali Oracle:

### Script Linux/Unix (Bash)
1. **`changepwd.sh`**: Cambia la password di un utente Oracle e la salva in Vault
2. **`oracleWalletToolkit.sh`**: Toolkit completo per la gestione del wallet Oracle con integrazione Vault
3. **`alter_user.sh`**: Script di supporto che esegue l'ALTER USER nel database

### Script Windows (PowerShell)
1. **`oracleWalletToolkit.ps1`**: Port PowerShell del toolkit wallet Oracle su Windows

### Workflow Tipico

**Linux/Unix (Bash):**
```
┌─────────────────────────────────────────────────────────────────┐
│                    GESTIONE CREDENZIALI ORACLE                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   1. Cambio Password          │
              │   (changepwd.sh)              │
              │                               │
              │  • Genera nuova password      │
              │  • Esegue ALTER USER          │
              │  • Salva in Vault             │
              └───────────┬───────────────────┘
                          │
                          ▼
              ┌───────────────────────────────┐
              │   2. Gestione Wallet          │
              │   (oracleWalletToolkit.sh)    │
              │                               │
              │  • Legge password da Vault    │
              │  • Configura wallet Oracle    │
              │  • Testa connessione          │
              └───────────────────────────────┘
```

**Windows (PowerShell):**
```
┌─────────────────────────────────────────────────────────────────┐
│             CONFIGURAZIONE WALLET ORACLE (Windows)               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   Gestione Wallet             │
              │   (oracleWalletToolkit.ps1)   │
              │                               │
              │  • Auto-discovery vault_lib   │
              │  • Legge password da Vault    │
              │  • Configura wallet Oracle    │
              │  • Testa connessione          │
              └───────────────────────────────┘
```

**Quando usare quale script:**
- **changepwd.sh**: Per creare/cambiare password utente Oracle e memorizzarla in Vault
- **oracleWalletToolkit.sh**: Per gestire il wallet Oracle (configurazione, creazione, test, lista credenziali)
- Sequenza consigliata: prima `changepwd.sh` (crea password), poi `oracleWalletToolkit.sh` (configura wallet)

---

## 🧪 Modalità Dry-Run

Tutti gli script supportano la **modalità dry-run** per visualizzare le operazioni senza eseguirle effettivamente. Questa funzionalità è essenziale per:

- ✅ **Verificare parametri**: Controllare che tutti i parametri siano corretti prima dell'esecuzione
- ✅ **Testing sicuro**: Testare gli script in ambienti di produzione senza rischi
- ✅ **Documentazione**: Generare documentazione delle operazioni svolte
- ✅ **Debugging**: Identificare problemi senza modificare lo stato del sistema

### Come usare la Dry-Run

**Bash (Linux/Unix):**
```bash
# Aggiungere il parametro -d alla fine del comando
./changepwd.sh -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_pass' -d
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL -t /path/to/wallet -o appuser -w 'wallet_pass' -U vault_user -P 'vault_pass' -d
```

**PowerShell (Windows):**
```powershell
# Aggiungere lo switch -DryRun (nessun valore necessario)
.\oracleWalletToolkit.ps1 -DbUser "A_IDL" -OracleInstance "SVI0" -Environment "svi" -DbAlias "SVI0_A_IDL" -TnsAdmin "C:\wallet" -MasterWallet "wallet_pass" -VaultUsername "vault_user" -VaultPassword "vault_pass" -DryRun
```

### Output in Modalità Dry-Run

In modalità dry-run, gli script mostrano in **blu** tutte le operazioni con il prefisso **`[DRY-RUN]`**:

```
========================================
DRY-RUN MODE ENABLED
No changes will be made
========================================

[DRY-RUN] Would generate new password: Example_Pass123
[DRY-RUN] Would execute SQL: ALTER USER A_IDL IDENTIFIED BY "***"
[DRY-RUN] Would login to Vault with user: vault_user
[DRY-RUN] Would save to Vault path: svi/paas/oracle/svi0/A_IDL
[DRY-RUN] Would update metadata with: host=server01,environment=svi

========================================
SUMMARY (Dry-Run)
Operations that would be performed:
  ✓ Generate password (28 chars)
  ✓ Update database password
  ✓ Login to Vault
  ✓ Save credentials to Vault
  ✓ Update metadata
========================================
No actual changes were made
========================================
```

💡 **Raccomandazione**: Eseguire sempre con `-d` / `-DryRun` prima di lanciare su produzione!

---

## Scripts

### 1. `changepwd.sh` - Script Principale

Script orchestratore che gestisce l'intero processo di cambio password con integrazione Vault.

**🔑 Caratteristiche principali:**
- Completamente parametrico: tutti i valori passati via command line
- Nessuna dipendenza da file di configurazione esterni
- Auto-contenuto: genera password sicure e gestisce tutto il workflow
- Integrazione nativa con HashiCorp Vault

#### Utilizzo

```bash
./changepwd.sh -u <db_user> -i <service_instance> -e <environment> -U <vault_user> -P <vault_pass> [-d]
```

#### Parametri

| Parametro | Descrizione | Obbligatorio |
|-----------|-------------|--------------|  
| `-u` | Nome utente database Oracle | ✓ |
| `-i` | Nome istanza Oracle (es: SVI0, PRD1) | ✓ |
| `-e` | Codice ambiente (svi, int, tst, pre, prd, amm) | ✓ |
| `-U` | Username per autenticazione Vault | ✓ |
| `-P` | Password per autenticazione Vault | ✓ |
| `-d` | Modalità dry-run (mostra cosa verrebbe fatto senza farlo) | |

```bash
# Cambio password per utente A_IDL su istanza SVI0 in ambiente sviluppo
./changepwd.sh -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_password'

# Cambio password per utente U_BATCH su istanza PRD1 in produzione
./changepwd.sh -u U_BATCH -i PRD1 -e prd -U vault_user -P 'vault_password'

# Modalità dry-run: vedere cosa verrebbe fatto senza eseguirlo
./changepwd.sh -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_password' -d

# Esempio con output:
# DB User: A_IDL
# Service Instance: SVI0
# Oracle Environment File: /usr/local/bin/oraenv_SVI0
# Vault credentials loaded from parameters
# Generating secure random password...
# Generated password for user: A_IDL
# Vault path: svi/paas/oracle/svi0
# Changing password in Oracle database...
# Oracle environment loaded: /usr/local/bin/oraenv_SVI0
# ✓ Password changed successfully in database
# Logging into Vault...
# ✓ Credentials saved to Vault
# ✓ Metadata updated in Vault
# ========================================
# Password change completed successfully!
# ========================================
```

#### Funzionalità

1. **Validazione parametri**: Controlla che tutti i parametri obbligatori siano presenti e validi
2. **Generazione password sicura**: Crea una password random di 28 caratteri alfanumerici (base64)
3. **Source environment Oracle**: Carica automaticamente l'environment Oracle da `/usr/local/bin/oraenv_<INSTANCE>`
4. **Cambio password Oracle**: Esegue l'ALTER USER nel database come utente `oracle`
5. **Salvataggio Vault**: Memorizza le nuove credenziali in Vault al path `<env>/paas/oracle/<instance>/<user>`
6. **Aggiornamento metadata**: Registra informazioni aggiuntive (host, environment, instance, timestamp) in Vault
7. **Logging completo**: Output colorato con indicazioni chiare di successo/errore

#### Workflow Interno

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Validazione Parametri                                        │
│    ✓ Verifica presenza di tutti i parametri obbligatori        │
│    ✓ Valida formato environment (svi|int|tst|pre|prd|amm)      │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Setup Environment                                             │
│    ✓ Carica vault_lib.sh                                        │
│    ✓ Verifica/installa jq                                       │
│    ✓ Costruisce path Vault                                      │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Generazione Password                                         │
│    ✓ openssl rand -base64 21 | tr -d '/+=' | cut -c1-28       │
│    ✓ Password sicura di 28 caratteri                           │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Cambio Password Oracle                                       │
│    ✓ Source oraenv_<INSTANCE>                                  │
│    ✓ Esegue alter_user.sh come utente oracle                   │
│    ✓ ALTER USER <user> IDENTIFIED BY "<new_password>"          │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Salvataggio in Vault                                         │
│    ✓ Login a Vault con credenziali fornite (-U/-P)            │
│    ✓ Salva credenziali: hc_vault_create                       │
│    ✓ Aggiorna metadata: hc_vault_create_info_metadata         │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
                   [ SUCCESSO ]
```

#### Requisiti

- File `vault_lib.sh` presente in `/products/software/sysadm/`
- Utility `jq` installata (lo script tenta l'installazione automatica)
- File `oraenv_<INSTANCE>` presente in `/usr/local/bin/`
- Credenziali Vault valide (username e password)

---

### 2. `oracleWalletToolkit.sh` - Toolkit Wallet Oracle

Toolkit completo per la gestione del wallet Oracle con integrazione HashiCorp Vault. Versione Bash di `oracleWalletToolkit.ps1`.

**🔑 Caratteristiche principali:**
- Completamente parametrico: tutti i valori passati via command line
- Integrazione nativa con HashiCorp Vault per recupero credenziali
- Gestione automatica wallet Oracle con mkstore e orapki
- Modalità multiple: configurazione, creazione, lista, test, auto-login-local, eliminazione credenziale
- Test automatico di tutte le connessioni con report riepilogativo
- Auto-discovery di `vault_lib.sh` e `vault_create_tnsnames.sh` in `/products/software/sysadm/`
- Output colorato e logging opzionale su file

#### Utilizzo

```bash
./oracleWalletToolkit.sh -u <db_user> -i <oracle_instance> -e <environment> -a <db_alias> \
                         -t <tns_admin> -o <os_user> -w <master_wallet> \
                         -U <vault_user> -P <vault_pass> [opzioni]
```

#### Parametri

| Parametro | Descrizione | Obbligatorio |
|-----------|-------------|--------------|
| `-u` | Nome utente database Oracle | ✓ (modalità configurazione) |
| `-i` | Nome istanza Oracle (es: svi0, prd1) | ✓ (modalità configurazione) |
| `-e` | Codice ambiente (svi, int, tst, pre, prd, amm) | ✓ (modalità configurazione) |
| `-a` | TNS alias per la connessione (es: SVI0_A_IDL) | ✓ (modalità configurazione) |
| `-t` | Path completo alla directory TNS_ADMIN (wallet) | ✓ |
| `-o` | Utente OS proprietario del wallet | ✓ (modalità configurazione) |
| `-w` | Password del master wallet | ✓ |
| `-U` | Username per autenticazione Vault | ✓ (modalità configurazione) |
| `-P` | Password per autenticazione Vault | ✓ (modalità configurazione) |
| `-c` | Crea wallet se non esiste | |
| `-L` | Lista credenziali wallet ed esci | |
| `-T` | Testa tutte le credenziali wallet e mostra report | |
| `-A` | Converte wallet in auto-login-local (CIS compliant) | |
| `-D` | Elimina una credenziale dal wallet (richiede `-a`) | |
| `-d` | Modalità dry-run (mostra cosa verrebbe fatto senza farlo) | |
| `-b` | Bare mode: output minimale, disabilita colori | |
| `-l` | Path del file di log opzionale | |
| `-h` | Mostra messaggio di aiuto | |

#### Esempi di Utilizzo

```bash
# Configurazione credenziale per utente A_IDL su istanza svi0
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL \
  -t /app/user/SVI0/conf/base/service/tns_admin \
  -o appuser -w 'wallet_password' \
  -U vault_user -P 'vault_pass'

# Configurazione con creazione wallet se non esiste
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL \
  -t /app/user/SVI0/conf/base/service/tns_admin \
  -o appuser -w 'wallet_password' \
  -U vault_user -P 'vault_pass' -c

# Creazione wallet standalone (senza Vault)
./oracleWalletToolkit.sh -t /app/user/SVI0/conf/base/service/tns_admin \
  -w 'wallet_password' -c

# Lista credenziali presenti nel wallet
./oracleWalletToolkit.sh -t /app/user/SVI0/conf/base/service/tns_admin \
  -w 'wallet_password' -L

# Test di tutte le connessioni nel wallet con report
./oracleWalletToolkit.sh -t /app/user/SVI0/conf/base/service/tns_admin \
  -w 'wallet_password' -T

# Conversione wallet in auto-login-local (CIS compliant)
./oracleWalletToolkit.sh -t /app/user/SVI0/conf/base/service/tns_admin \
  -w 'wallet_password' -A

# Eliminazione di una credenziale dal wallet
./oracleWalletToolkit.sh -t /app/user/SVI0/conf/base/service/tns_admin \
  -w 'wallet_password' -a SVI0_A_IDL -D

# Dry-run: vedere cosa verrebbe fatto senza eseguirlo
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL \
  -t /app/user/SVI0/conf/base/service/tns_admin \
  -o appuser -w 'wallet_password' \
  -U vault_user -P 'vault_pass' -d

# Con output su file di log
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL \
  -t /app/user/SVI0/conf/base/service/tns_admin \
  -o appuser -w 'wallet_password' \
  -U vault_user -P 'vault_pass' -l /var/log/wallet_setup.log
```

#### Funzionalità

1. **Validazione parametri**: Controlla la presenza e validità di tutti i parametri
2. **Auto-discovery librerie**: Trova automaticamente `vault_lib.sh` e `vault_create_tnsnames.sh` in `/products/software/sysadm/`
3. **Gestione tnsnames.ora**: Verifica e crea automaticamente le entry TNS via `vault_create_tnsnames.sh`
4. **Check Vault status**: Verifica che il Vault sia unsealed
5. **Login Vault**: Autenticazione con credenziali fornite
6. **Recupero credenziali**: Legge la password utente da Vault al path `<env>/paas/oracle/<instance>/<user>`
7. **Configurazione wallet**: Crea o aggiorna le credenziali nel wallet usando mkstore
8. **Test connessione**: Verifica la connettività usando il wallet appena configurato
9. **Aggiornamento metadata**: Registra informazioni in Vault (host, environment, alias, tns_admin)
10. **Modalità aggiuntive**: Lista (`-L`), test massivo (`-T`), auto-login-local (`-A`), eliminazione (`-D`)

#### Workflow Interno

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Validazione e Setup                                          │
│    ✓ Verifica parametri obbligatori                            │
│    ✓ Auto-discovery vault_lib.sh e vault_create_tnsnames.sh   │
│    ✓ Setup colori e log file                                   │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Gestione Wallet (se -c)                                      │
│    ✓ Verifica esistenza wallet                                 │
│    ✓ Crea wallet con orapki se richiesto                      │
│    ✓ Crea sqlnet.ora e tnsnames.ora se assenti               │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Controllo Vault                                              │
│    ✓ Verifica status Vault (hc_vault_is_sealed)               │
│    ✓ Login a Vault (hc_vault_login)                           │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Recupero Credenziali                                         │
│    ✓ Legge password da Vault (hc_vault_read)                  │
│    ✓ Path: <env>/paas/oracle/<instance>/<user>                │
│    ✓ Salva in file temporaneo /tmp/temp_cred_$$.txt           │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Configurazione Wallet                                        │
│    ✓ Verifica/genera tnsnames.ora via vault_create_tnsnames.sh│
│    ✓ Tenta mkstore -createCredential                          │
│    ✓ Se esiste già: mkstore -modifyCredential                 │
│    ✓ Esecuzione come utente proprietario wallet (sudo -u)     │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Test e Metadata                                              │
│    ✓ Test connessione: sqlplus /@<db_alias>                   │
│    ✓ Aggiorna metadata in Vault                               │
│    ✓ Cleanup file temporanei (trap EXIT)                      │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
                   [ SUCCESSO ]
```

#### Requisiti

- Permessi per eseguire comandi come utente proprietario del wallet (tramite sudo)
- File `vault_lib.sh` presente in `/products/software/sysadm/` (auto-discovery)
- Utility `mkstore`, `sqlplus`, `orapki` nel PATH
- Directory TNS_ADMIN esistente (o flag `-c` per crearla)
- Credenziali Vault valide e password già presente in Vault
- Vault unsealed (lo script non gestisce l'unseal per sicurezza)

#### Note Importanti

- Le credenziali devono **già esistere in Vault** (create ad esempio con `changepwd.sh`)
- Lo script **NON crea** nuove password, le recupera solo da Vault
- La master wallet password è richiesta per sbloccare il wallet Oracle
- Il test di connessione usa la sintassi `connect /@<alias>` che richiede wallet configurato
- I file temporanei (`/tmp/temp_cred_$$.txt`) vengono eliminati automaticamente al termine (trap EXIT)
- Con `-T` il report finale mostra tutti gli alias testati con esito successo/fallimento

---

### 3. `alter_user.sh` - Script Cambio Password Oracle

Script che esegue fisicamente il cambio password sul database Oracle.

#### Utilizzo

```bash
./alter_user.sh <db_user> <db_user_password> <oraenv_file>
```

#### Parametri

| Posizione | Nome | Descrizione |
|-----------|------|-------------|
| 1 | db_user | Nome utente database |
| 2 | db_user_password | Nuova password |
| 3 | oraenv_file | Path completo al file Oracle environment (es: /usr/local/bin/oraenv_SVI0) |

#### Esempio

```bash
su oracle -c "./alter_user.sh A_IDL 'MyNewP@ssw0rd!' /usr/local/bin/oraenv_SVI0"
```

#### Note

- **NON** usare direttamente: è pensato per essere chiamato da `changepwd.sh`
- Deve essere eseguito come utente `oracle`
- Il parametro `oraenv_file` deve essere il path completo al file di environment Oracle
- Gestisce trap per errori ed esegue cleanup automatico

---

## Vault Integration

### Path Structure

Le credenziali vengono salvate nel vault seguendo questa struttura:

```
<environment>/paas/oracle/<instance>/<username>
```

**Esempi:**
- `svi/paas/oracle/svi0/A_IDL`
- `prd/paas/oracle/prd1/U_BATCH`

### Metadata

Per ogni credenziale vengono registrati i seguenti metadati:

**Per changepwd.sh:**
- `host`: Hostname del server che ha effettuato il cambio
- `environment`: Codice ambiente
- `instance`: Nome istanza Oracle
- `user`: Nome utente database
- `method`: Tipo operazione (changepwd)

**Per oracleWalletToolkit.sh / oracleWalletToolkit.ps1:**
- `host`: Hostname del server che ha configurato il wallet
- `environment`: Codice ambiente
- `instance`: Nome istanza Oracle
- `alias`: TNS alias configurato
- `tns_admin`: Path del wallet
- `method`: Tipo operazione (configwallet)

---

## Windows / PowerShell Scripts

### `oracleWalletToolkit.ps1` - Toolkit Wallet Oracle (PowerShell)

Port PowerShell del toolkit `oracleWalletToolkit.sh` per sistemi Windows con integrazione HashiCorp Vault.

**🔑 Caratteristiche principali:**
- Parità funzionale completa con la versione Bash
- Compatibile con **PowerShell 2.0+** (incluso Windows Server 2008)
- Auto-discovery di `vault_lib.ps1` e `vault_create_tnsnames.ps1` in `C:\products\software\sysadm\`
- Input password a mkstore via pipe binaria raw (gestisce correttamente le terminazioni di riga Windows)
- Modalità multiple: configurazione, creazione wallet, lista, test, auto-login-local, eliminazione credenziale
- Output colorato e logging opzionale su file

#### Requisiti

- Windows con **PowerShell 2.0 o superiore** (compatibile con Windows Server 2008+)
- Oracle Client installato: `mkstore.exe`, `sqlplus.exe`, `orapki.exe` nel PATH o via `-OracleBinPath`
- `vault_lib.ps1` (auto-discoverto in `C:\products\software\sysadm\` o via `-VaultLibPath`)
- Credenziali già presenti in Vault (in modalità configurazione)
- Wallet Oracle già creato nel path TNS_ADMIN (o `-CreateWallet` per crearlo)

#### Parametri

| Parametro | Descrizione | Obbligatorio |
|-----------|-------------|--------------|
| `-DbUser` | Nome utente database Oracle | ✓ (modalità configurazione) |
| `-OracleInstance` | Nome istanza Oracle (es: SVI0, PRD1) | ✓ (modalità configurazione) |
| `-Environment` | Codice ambiente (svi, int, tst, pre, prd, amm) | ✓ (modalità configurazione) |
| `-DbAlias` | TNS alias per la connessione | ✓ (modalità configurazione) |
| `-TnsAdmin` | Path directory TNS_ADMIN (wallet) | ✓ |
| `-OsUser` | Utente OS proprietario del wallet (informativo su Windows) | |
| `-MasterWallet` | Password del master wallet | ✓ |
| `-VaultUsername` | Username Vault | ✓ (modalità configurazione) |
| `-VaultPassword` | Password Vault | ✓ (modalità configurazione) |
| `-VaultLibPath` | Path a vault_lib.ps1 (auto-discoverto se non specificato) | |
| `-OracleBinPath` | Directory bin Oracle Client aggiunta al PATH se necessario (default: `C:\products\software\oracle_193000\client_193000\bin`) | |
| `-VaultCreateTnsnamesPath` | Path a vault_create_tnsnames.ps1 (auto-discoverto se non specificato) | |
| `-CreateWallet` | Crea wallet se non esiste (switch) | |
| `-ListWallet` | Lista credenziali wallet ed esci (switch) | |
| `-TestWallet` | Testa tutte le credenziali wallet e mostra report (switch) | |
| `-AutoLoginLocal` | Converte wallet in auto-login-local CIS compliant (switch) | |
| `-DeleteCredential` | Elimina una credenziale dal wallet, richiede `-DbAlias` (switch) | |
| `-DryRun` | Modalità dry-run - mostra cosa verrebbe fatto senza modificare nulla (switch) | |
| `-Bare` | Output minimale, disabilita colori (switch) | |
| `-LogFile` | Path del file di log opzionale | |

#### Esempi di Utilizzo

```powershell
# Configurazione credenziale wallet per utente A_IDL su istanza SVI0
.\oracleWalletToolkit.ps1 `
    -DbUser "A_IDL" `
    -OracleInstance "SVI0" `
    -Environment "svi" `
    -DbAlias "SVI0_A_IDL" `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" `
    -VaultUsername "vault_user" `
    -VaultPassword "vault_pass"

# Configurazione con creazione wallet se non esiste
.\oracleWalletToolkit.ps1 `
    -DbUser "A_IDL" -OracleInstance "SVI0" -Environment "svi" -DbAlias "SVI0_A_IDL" `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" `
    -VaultUsername "vault_user" -VaultPassword "vault_pass" -CreateWallet

# Creazione wallet standalone (senza Vault)
.\oracleWalletToolkit.ps1 `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" -CreateWallet

# Lista credenziali presenti nel wallet
.\oracleWalletToolkit.ps1 `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" -ListWallet

# Test di tutte le connessioni nel wallet con report
.\oracleWalletToolkit.ps1 `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" -TestWallet

# Conversione wallet in auto-login-local (CIS compliant)
.\oracleWalletToolkit.ps1 `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" -AutoLoginLocal

# Eliminazione di una credenziale dal wallet
.\oracleWalletToolkit.ps1 `
    -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" -DbAlias "SVI0_A_IDL" -DeleteCredential

# Configurazione in produzione con log file
.\oracleWalletToolkit.ps1 `
    -DbUser "U_BATCH" -OracleInstance "PRD1" -Environment "prd" -DbAlias "PRD1_U_BATCH" `
    -TnsAdmin "C:\app\user\PRD1\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" `
    -VaultUsername "vault_user" -VaultPassword "vault_pass" `
    -LogFile "C:\logs\wallet_setup.log"

# Dry-run per verificare senza eseguire
.\oracleWalletToolkit.ps1 `
    -DbUser "U_BATCH" -OracleInstance "PRD1" -Environment "prd" -DbAlias "PRD1_U_BATCH" `
    -TnsAdmin "C:\app\user\PRD1\conf\base\service\tns_admin" `
    -MasterWallet "wallet_password" `
    -VaultUsername "vault_user" -VaultPassword "vault_pass" -DryRun
```

#### Workflow PowerShell

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Validazione Parametri e Setup                                │
│    ✓ Valida -TnsAdmin e -MasterWallet (sempre obbligatori)    │
│    ✓ Auto-discovery vault_lib.ps1 e vault_create_tnsnames.ps1 │
│    ✓ Valida parametri modalità configurazione                  │
│    ✓ Setup colori e log file                                   │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Verifica Strumenti Oracle                                    │
│    ✓ Cerca mkstore, sqlplus, orapki nel PATH                  │
│    ✓ Aggiunge -OracleBinPath al PATH se necessario            │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Gestione Wallet (se -CreateWallet)                          │
│    ✓ Verifica esistenza cwallet.sso / ewallet.p12             │
│    ✓ Crea wallet con orapki -auto_login_local                 │
│    ✓ Crea sqlnet.ora e tnsnames.ora se assenti               │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Controllo Vault e Recupero Credenziali                      │
│    ✓ Import vault_lib.ps1 (dot-sourcing)                      │
│    ✓ Test-VaultSealed: verifica Vault non sigillato           │
│    ✓ Invoke-VaultLogin: autenticazione                        │
│    ✓ Get-VaultSecret: path <env>/paas/oracle/<inst>/<user>   │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Configurazione Wallet                                        │
│    ✓ Verifica/crea entry TNS via vault_create_tnsnames.ps1   │
│    ✓ mkstore -createCredential (primo tentativo)              │
│    ✓ mkstore -modifyCredential (se già esistente)             │
│    ✓ Input via pipe binaria raw (evita corruzione \r\n)       │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Test e Metadata                                              │
│    ✓ sqlplus -S /nolog: test connessione con wallet           │
│    ✓ Set-VaultSecretMetadata: aggiorna info in Vault          │
│    ✓ Invoke-Cleanup: rimuove file temporanei                  │
└────────────────────────┬────────────────────────────────────────┘
                         ↓
                   [ SUCCESSO ]
```

#### Note Specifiche Windows

- **Compatibilità PowerShell**: Lo script funziona con **PowerShell 2.0+** (Windows Server 2008 e successivi). Utilizza `-notcontains` al posto di `-notin` per compatibilità PS 2.0.
- **Execution Policy**: Potrebbe essere necessario eseguire `Set-ExecutionPolicy RemoteSigned` per permettere l'esecuzione di script
- **Oracle Client Path**: Il default è `C:\products\software\oracle_193000\client_193000\bin`; personalizzabile con `-OracleBinPath`
- **Auto-discovery librerie**: `vault_lib.ps1` e `vault_create_tnsnames.ps1` vengono cercati ricorsivamente in `C:\products\software\sysadm\`
- **Input mkstore**: L'input è inviato come byte raw ASCII con terminazione `\r\n` tramite `System.Diagnostics.Process` per bypassare problemi di encoding della pipeline PowerShell
- **File Temporanei**: Vengono creati in `$env:TEMP` e rimossi automaticamente tramite `Register-EngineEvent PowerShell.Exiting`
- **Test con -TestWallet**: Elenca tutte le credenziali e testa ogni connessione, producendo un report con successi e fallimenti

#### Differenze con la Versione Bash

| Aspetto | Bash (Linux/Unix) | PowerShell (Windows) |
|---------|------------------|---------------------|
| Parametri | Flag POSIX (`-u`, `-i`, `-e`, ...) | Named params (`-DbUser`, `-OracleInstance`, ...) |
| Ambiente Oracle | Variabili PATH esistenti | `-OracleBinPath` aggiunto dinamicamente al PATH |
| Esecuzione privilegi | `sudo -u <os_user>` | Eseguire come utente appropriato |
| Path separator | `/` | `\` |
| File temporanei | `/tmp/temp_cred_$$.txt` | `$env:TEMP\temp_cred_$PID.txt` |
| Input a mkstore | heredoc / echo pipe | Pipe binaria raw via `System.Diagnostics.Process` |
| Hostname | `hostname -f` | `$env:COMPUTERNAME` |
| Cleanup | `trap EXIT` | `Register-EngineEvent PowerShell.Exiting` |
| Colori output | Codici ANSI escape | `Write-Host -ForegroundColor` |
| Compatibilità PS | N/A | PowerShell 2.0+ (Windows Server 2008+) |

---

## Troubleshooting

### Errore: "Oracle environment file not found"

**Problema:** Il file oraenv non esiste nel path specificato

**Soluzione:**
```bash
# Verificare la presenza del file
ls -l /usr/local/bin/oraenv_*

# Creare il file se mancante (come utente oracle)
su - oracle
cat > /usr/local/bin/oraenv_SVI0 <<EOF
export ORACLE_SID=SVI0
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
EOF

chmod +x /usr/local/bin/oraenv_SVI0
```

### Errore: "Failed to login to Vault"

**Problema:** Credenziali Vault non valide o non fornite

**Soluzione:**
```bash
# Verificare che le credenziali Vault siano corrette
# Le credenziali devono essere passate come parametri -U e -P

# Esempio con credenziali corrette
./changepwd.sh -u A_IDL -i SVI0 -e svi -U correct_user -P 'correct_password'

# Verificare l'accesso al Vault
# Assicurarsi che l'utente abbia i permessi necessari per scrivere nel path:
# <environment>/paas/oracle/<instance>/<username>
```

### Errore: "Vault is sealed" (oracleWalletToolkit.sh)

**Problema:** Il Vault è sigillato e non può essere acceduto

**Soluzione:**
```bash
# Lo script oracleWalletToolkit.sh non gestisce l'unseal per sicurezza
# Effettuare manualmente l'unseal del Vault prima di eseguire lo script

# Verificare lo status del Vault
vault status

# Unseal (richiede chiavi di unseal)
vault operator unseal
```

### Errore: "Failed to retrieve credentials from Vault" (oracleWalletToolkit.sh)

**Problema:** Le credenziali non esistono nel Vault al path specificato

**Soluzione:**
```bash
# Prima di configurare il wallet, è necessario che le credenziali esistano in Vault
# Usare changepwd.sh per creare/aggiornare le credenziali in Vault

# Esempio: creare prima le credenziali
./changepwd.sh -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_pass'

# Poi configurare il wallet
./oracleWalletToolkit.sh -u A_IDL -i svi0 -e svi -a SVI0_A_IDL \
  -t /app/user/SVI0/conf/base/service/tns_admin \
  -o appuser -w 'wallet_pass' \
  -U vault_user -P 'vault_pass'
```

### Errore: "Connection test failed" (oracleWalletToolkit.sh)

**Problema:** Il test di connessione tramite wallet non riesce

**Soluzione:**
```bash
# Verificare che il TNS alias sia definito correttamente in tnsnames.ora
cat /path/to/tns_admin/tnsnames.ora | grep <DB_ALIAS>

# Verificare che il wallet sia leggibile
ls -l /path/to/tns_admin/cwallet.sso

# Testare manualmente la connessione
su - <oracle_user>
source /usr/local/bin/oraenv_<INSTANCE>
export TNS_ADMIN=/path/to/tns_admin
sqlplus /@<DB_ALIAS>
```

### Errori PowerShell Specifici (Windows)

#### Errore: "Execution Policy" impedisce l'esecuzione

**Problema:** La policy di esecuzione PowerShell blocca lo script

**Soluzione:**
```powershell
# Verificare la policy corrente
Get-ExecutionPolicy

# Impostare policy per permettere script locali (come amministratore)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Oppure eseguire singolo script bypassando la policy
PowerShell.exe -ExecutionPolicy Bypass -File .\oracleWalletToolkit.ps1 -DbUser "A_IDL" ...
```

#### Errore: "mkstore.exe not found"

**Problema:** mkstore.exe non trovato nel path ORACLE_HOME specificato

**Soluzione:**
```powershell
# Verificare il path ORACLE_HOME
$env:ORACLE_HOME
Get-ChildItem "$env:ORACLE_HOME\bin\mkstore.exe"

# Trovare Oracle Home se sconosciuto
Get-ChildItem -Path C:\ -Recurse -Filter "mkstore.exe" -ErrorAction SilentlyContinue

# Esempio path tipici:
# C:\oracle\product\19c\dbhome_1
# C:\app\oracle\product\19c\dbhome_1
# C:\oracle\product\12.2.0\dbhome_1
```

#### Errore: "Import-Module vault_lib.ps1" fallisce

**Problema:** Il modulo vault_lib.ps1 non viene trovato o importato

**Soluzione:**
```powershell
# Verificare che vault_lib.ps1 esista
Test-Path .\vault_lib.ps1

# Usare path assoluto
.\oracleWalletToolkit.ps1 -VaultLibPath "C:\Scripts\vault_lib.ps1" ...

# Verificare eventuali errori di sintassi nel modulo
Import-Module .\vault_lib.ps1 -Verbose
```

#### Errore: "Failed to configure wallet" su Windows

**Problema:** mkstore fallisce nella configurazione del wallet

**Soluzione:**
```powershell
# Verificare permessi directory wallet
icacls "C:\app\user\SVI0\conf\base\service\tns_admin"

# Verificare che il wallet sia stato creato
Get-ChildItem "C:\app\user\SVI0\conf\base\service\tns_admin\cwallet.sso"

# Creare wallet se non esiste (come utente appropriato)
cd C:\app\user\SVI0\conf\base\service\tns_admin
mkstore -wrl . -create
# Inserire master password quando richiesto

# Testare manualmente mkstore
mkstore -wrl C:\app\user\SVI0\conf\base\service\tns_admin -listCredential
```

### Errore: "Permission denied"

**Problema:** Script non eseguibile o permessi insufficienti

**Soluzione:**
```bash
# Rendere eseguibili gli script
chmod +x changepwd.sh
chmod +x alter_user.sh

# Eseguire con sudo se necessario
sudo ./changepwd.sh -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_password'
```

---

## Security Notes

⚠️ **Importante:**

- Le password generate sono random di 28 caratteri alfanumerici (base64, caratteri speciali rimossi)
- Le password non vengono mai loggate in chiaro (usare `-P` con attenzione nei log)
- Le credenziali Vault sono passate come parametri: evitare di salvarle in file di script
- L'accesso al Vault richiede autenticazione valida
- Solo l'utente `oracle` può eseguire ALTER USER nel database
- I file temporanei (`/tmp/outfile$$.out`) vengono eliminati automaticamente
- Lo script richiede `sudo` per eseguire comandi come utente `oracle`

**Best Practices:**
- 🧪 **Usare sempre la dry-run mode (`-d` / `-DryRun`) prima di eseguire su produzione**
- 🔒 Non salvare le credenziali Vault in file di configurazione
- 🔒 Usare variabili d'ambiente per le credenziali sensibili quando possibile
- 🔒 Verificare i permessi sui file oraenv (`chmod 644` o `640`)
- 🔒 Limitare l'accesso sudo solo agli utenti autorizzati
- 🔒 Monitorare i log di Vault per accessi sospetti
- 🔒 Per oracleWalletToolkit.sh: proteggere la master wallet password (non loggare, non salvare in chiaro)
- 🔒 I file temporanei di credenziali vengono automaticamente eliminati
- 🔒 Verificare regolarmente i permessi sui wallet Oracle (proprietario e gruppo corretti)

---

## Changelog

### Version 2.1 (2026-03-10)
- 🔄 Rinominato `configpwd.sh` → `oracleWalletToolkit.sh` (toolkit completo, port della versione PS)
- 🔄 Rinominato `configpwd.ps1` → `oracleWalletToolkit.ps1` (toolkit completo con modalità multiple)
- 🔧 **Fix compatibilità PowerShell 2.0** (Windows Server 2008): operatore `-notin` sostituito con `-notcontains`
- ✨ Aggiunto supporto modalità: `-CreateWallet`/`-c`, `-ListWallet`/`-L`, `-TestWallet`/`-T`, `-AutoLoginLocal`/`-A`, `-DeleteCredential`/`-D`
- ✨ Auto-discovery di `vault_lib.ps1`/`vault_lib.sh` e `vault_create_tnsnames.ps1`/`vault_create_tnsnames.sh`
- ✨ Input mkstore via pipe binaria raw su Windows (gestione corretta `\r\n`)
- ✨ Aggiunto parametro `-Bare`/`-b` per output minimale e `-LogFile`/`-l` per logging su file
- ✨ Test massivo con `-TestWallet`/`-T` e report riepilogativo connessioni

### Version 2.0 (2026-02-24)
- ✨ Refactoring completo da template ERB a script parametrico
- ✨ Aggiunto script orchestratore `changepwd.sh` per cambio password con Vault (Linux/Unix)
- ✨ Aggiunto script orchestratore `configpwd.sh` per configurazione wallet Oracle (Linux/Unix)
- ✨ **Nuove versioni PowerShell per Windows**:
  - 🪟 `vault_lib.ps1`: Libreria completa Vault API per PowerShell
  - 🪟 `configpwd.ps1`: Configurazione wallet Oracle su Windows
- ✨ **Modalità Dry-Run**: Visualizzazione operazioni senza eseguirle
  - 🧪 Bash: parametro `-d` per changepwd.sh e configpwd.sh
  - 🧪 PowerShell: switch `-DryRun` per configpwd.ps1
  - 🧪 Output colorato in blu con prefisso `[DRY-RUN]`
- ✨ Integrazione completa con Vault (credenziali come parametri -U e -P)
- ✨ Path oraenv personalizzabile (non più hardcoded)
- ✨ Gestione automatica wallet: creazione e aggiornamento credenziali
- ✨ Test automatico connessione wallet con verifica SQL
- ✨ Migliorato error handling e logging con output colorato
- ✨ Aggiunta validazione completa parametri con ValidateSet
- ✨ Documentazione completa con esempi, workflow diagrams e troubleshooting
- ✨ **Supporto cross-platform**: Linux/Unix (Bash) e Windows (PowerShell)
- ✨ Rimossa dipendenza da file di configurazione esterni
- ✨ Cleanup automatico file temporanei con trap/event handlers

### Version 1.0 (legacy)
- Script basato su template ERB
- Richiede generazione dinamica per ogni utente

---

## Autori

- Refactoring e parametrizzazione: 2026
- Script originale: team ops-sysadm
