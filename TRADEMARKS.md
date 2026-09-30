# Trademarks & Non-Affiliation

**Harmomeow Craft Launcher** is an unofficial, third-party Minecraft: Java
Edition launcher for HarmonyOS / OpenHarmony (2-in-1 / PC devices).

* **Minecraft** is a trademark of Mojang Synergies AB / Microsoft.
* **Microsoft**, **Xbox**, **Xbox Live**, and **Microsoft Store** are trademarks
  of Microsoft Corporation.
* **HarmonyOS** / **OpenHarmony** are trademarks of their respective owners.

This project is **not affiliated with, endorsed by, or sponsored by** Mojang,
Microsoft, or the OpenHarmony project.

This project does **not** distribute Minecraft game files or assets. Users must
supply their own legitimately-obtained copy of Minecraft (the launcher installs
the game from Mojang's own public servers, or uses an existing `.minecraft`
directory). Microsoft / Xbox Live account sign-in is performed against
Microsoft's public OAuth services, under the user's own Microsoft account, using
the OAuth **device-code** flow (no client secret is bundled; the user supplies
their own Azure public client id).

This project distributes no Mojang code. The clean-room narrator stub
(`com.mojang.text2speech`, previously bundled inside our own `launcher.jar`)
was removed on 2026-10-01 together with the clean-room `meow.launcher`; the
game now uses the real `text2speech` library declared by the version manifest
(if any). Any remaining source references to Mojang class/package names are
purely for **interoperability** with the Minecraft client.
