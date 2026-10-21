# Personalizzazione (1.1)

Cosa si può cambiare, dove è memorizzato e che garanzie ci sono per chi aggiorna da una versione precedente.

## Cosa c'è

**Impostazioni ▸ Aspetto ▸ Personalizza la Home**
* Per ogni sezione (In evidenza, Continua a guardare, Prossimi episodi, Watchlist, Cataloghi degli addon): visibile o nascosta, posizione («Riordina», oppure le azioni VoiceOver «Sposta su / Sposta giù»).
* Stile delle schede: **locandina** (verticale), **orizzontale** (16:9, come «Continua a guardare» in Libreria) e, solo per «Prossimi episodi», **compatta**. Dimensione: piccola, media, grande, oppure «Auto» (segue la dimensione generale scelta in Aspetto).
* «In evidenza»: **Card** (come nella 1.0) oppure **Schermo intero** (immagine da bordo a bordo che sfuma nella pagina, titolo in sovrimpressione), con o senza scorrimento automatico.
* Saluto in cima alla Home (facoltativo) con il tuo nome.

**Impostazioni ▸ Aspetto ▸ Stile e grafica**
* Atmosfera (colori dello sfondo): Aether (segue l'accento), Tramonto, Oceano, Foresta, Zucchero filato, Mezzanotte, Sala buia; una ottava è nascosta.
* Sfondo: Aurora (come nella 1.0), Onde (si muove piano), Faro, Tinta unita.
* Cornice delle schede: Standard, Contorno, Ombra, Alone. Angoli: Netti, Standard, Morbidi, Bolle. Carattere dei titoli: Arrotondato, Classico, Con grazie, Macchina da scrivere.

I valori predefiniti riproducono la 1.0: nulla cambia finché non si sceglie.

## Dove è memorizzato

Tutto in `AppearanceSettings` (`AppSettings.swift`), nello stesso JSON delle altre impostazioni (chiave `aether.settings.v1`). Chiavi nuove: `heroStyle`, `heroAutoScroll`, `palette`, `backdrop`, `cardChrome`, `cornerStyle`, `titleFont`, `greetingEnabled`, `greetingName`, `unlockedSecrets`; ogni sezione in `homeSections` ha in più `style` e `size` (facoltativi). Le chiavi `theme`, `accent`, `posterSize`, `density` non sono cambiate.

## Garanzie di compatibilità (coperte da test in `AppearanceCustomizationTests`)

* Le sezioni salvate dalla 1.0 (solo `id` e `isVisible`) si rileggono con ordine e visibilità intatti: `HomeSectionConfig` ha un decodificatore scritto a mano. Con quello generato dal compilatore ogni sezione vecchia sarebbe stata scartata e la Home sarebbe tornata all'ordine di fabbrica **senza avvisare**.
* Un valore sconosciuto (un file di una versione più nuova, o modificato a mano) torna al predefinito senza buttare il resto: `"palette":"vaporwave"` diventa Aether, le altre scelte restano.
* Uno stile che una sezione non offre (la scheda compatta per la Watchlist) viene scartato e la sezione usa il suo predefinito.
* Il nome del saluto è limitato a 24 caratteri, su una riga. **Finisce nel backup delle impostazioni, che non è cifrato.**
* Le impostazioni «segrete» sono memorizzate per identificativo (`unlockedSecrets`); un'atmosfera segreta non ancora trovata non può essere scelta nemmeno modificando il file.

## Leggibilità

Le atmosfere colorano solo gli aloni decorativi dietro i contenuti (al massimo il 30 % di opacità), mai il testo. `AppearanceCustomizationTests.testEveryPaletteKeepsTextReadable` calcola per ogni colore e per tema chiaro e scuro il contrasto del testo principale (soglia 7:1) e di quello secondario al 72 % (soglia 4,5:1). Lo sfondo «Onde» si ferma con «Animazioni» spente, «Riduci movimento», Risparmio energetico o app non in primo piano, e diventa uniforme con «Riduci gli effetti visivi».

## Come è fatto

Un solo valore d'ambiente, `AetherStyle`, iniettato sopra tutta l'app (`ThemedRoot`), così arriva anche a fogli e schermate a tutto schermo. Lo leggono `PosterCard`, le schede orizzontali, «Continua a guardare», «Prossimi episodi», il carosello e lo sfondo. Il carattere dei titoli passa da `AetherTypography`, letto dalle funzioni `Font.aether…` e dalle ~20 chiamate `.system(…, design:)` delle schermate di Aether; il selettore di sorgenti (pillole TorBox) resta volutamente fuori, perché ha test di geometria sul carattere predefinito.

## Limiti noti

* **Non ho visto nessuna di queste schermate su un dispositivo né in una schermata.** I test controllano numeri (larghezze delle schede, ordine, altezza del carosello) e comportamenti, non l'estetica.
* «Schermo intero» parte *sotto* il titolo «Home» e la barra: non passa ancora sotto la barra di stato come nella scheda di dettaglio. Dipende da come lo vedi su un iPhone vero.
* Il cambio del carattere dei titoli si applica subito alle schermate che hanno `@EnvironmentObject` sulle impostazioni; alcune schede già disegnate lo prendono quando vengono ridisegnate (scorrendo o riaprendo la schermata).
