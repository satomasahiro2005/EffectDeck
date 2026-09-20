// EffectDeck が自前で持つ kernel（docs/virtual-room-design.md §48）。
// 上流の dsp/registry.inc と同じ書き方にしてある。上流へ出すときは、この 1 行を
// あちらの registry.inc の spatial の所へ移すだけで済む。
//
// 読み込むのは Patches/effetune-local-kernels.diff が開けた口から。
// ET_EFFECTDECK_EXTENSIONS を立てたビルドだけがここを見る。
EFFETUNE_PLUGIN(VirtualRoomPlugin, spatial/virtual_room)
