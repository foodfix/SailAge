extends RefCounted
## Verbatim copy of the **docs/60-COMBAT.md §4.12.5** `ui_strings.json` inventory
## (41 keys, both locales), used by the S10 battle screen only while
## `data/ui_strings.json` does not yet carry them.
##
## **TEMPORARY BRIDGE — delete this file (and the `_t()` fallback in
## `battle_screen.gd`) once task G lands the §4.12.5 keys in
## `data/ui_strings.json`.** Nothing here is new text: every value is copied
## from the pinned doc table, and the placeholders are the doc's own
## (`{round}`, `{attacker}`, …), so a screen reads identically before and after
## the merge.
##
## The screen never prints a raw `<key>` (docs/80-* §6), so a missing data key
## falls back to this table instead of `I18n.t_key()`'s bug marker.

const DOC_STRINGS := {
	"battle.title": {"zh": "海战", "en": "Battle"},
	"battle.round": {"zh": "第 {round} 回合", "en": "Round {round}"},
	"battle.action.cannon": {"zh": "炮击", "en": "Cannon"},
	"battle.action.ram": {"zh": "撞击", "en": "Ram"},
	"battle.action.board": {"zh": "接舷", "en": "Board"},
	"battle.action.hold": {"zh": "待命", "en": "Hold"},
	"battle.action.retreat": {"zh": "撤退", "en": "Retreat"},
	"battle.action.surrender": {"zh": "投降", "en": "Surrender"},
	"battle.reload": {"zh": "装填中", "en": "Reloading"},
	"battle.target.none": {"zh": "未选定目标", "en": "No target selected"},
	"battle.log.cannon": {"zh": "{attacker} 炮击 {target},造成 {damage} 点伤害。", "en": "{attacker} fires on {target} for {damage} damage."},
	"battle.log.ram": {"zh": "{attacker} 撞击 {target},自身受损 {self_damage} 点。", "en": "{attacker} rams {target}, taking {self_damage} damage."},
	"battle.log.sunk": {"zh": "{ship} 沉没了。", "en": "{ship} has sunk."},
	"battle.log.turn": {"zh": "轮到 {ship}。", "en": "{ship} to act."},
	"battle.duel.start": {"zh": "接舷战!", "en": "Boarding action!"},
	"battle.duel.round": {"zh": "第 {round} 回合:{player} 对 {defender}", "en": "Round {round}: {player} vs {defender}"},
	"battle.result.victory": {"zh": "胜利!", "en": "Victory!"},
	"battle.result.defeat": {"zh": "战败。", "en": "Defeat."},
	"battle.result.retreat": {"zh": "你脱离了战斗。", "en": "You disengaged from the battle."},
	"battle.result.surrender": {"zh": "你投降了。", "en": "You surrendered."},
	"battle.after.title": {"zh": "战后", "en": "After the battle"},
	"battle.after.loot": {"zh": "打捞所得 {gold} 金。", "en": "Salvage: {gold} gold."},
	"battle.after.xp": {"zh": "获得 {xp} 点经验。", "en": "Experience gained: {xp}."},
	"battle.after.captured": {"zh": "俘获 {ship}!", "en": "Captured {ship}!"},
	"battle.after.scuttled": {"zh": "船队已满,{ship} 被拆解。", "en": "Fleet full — {ship} was scuttled."},
	"battle.after.overflow": {"zh": "{count} 单位货物因舱位不足而丢失。", "en": "{count} units of cargo were lost for lack of hold space."},
	"battle.after.lost": {"zh": "你失去了 {ship}。", "en": "You lost {ship}."},
	"battle.surrender.confirm": {"zh": "确定要投降吗?", "en": "Surrender the battle?"},
	"battle.retreat.confirm": {"zh": "确定要撤退吗?", "en": "Retreat from the battle?"},
	"duel.title": {"zh": "船长决斗", "en": "Captain's Duel"},
	"duel.round.win": {"zh": "胜", "en": "Win"},
	"duel.round.loss": {"zh": "负", "en": "Loss"},
	"duel.round.tie": {"zh": "平", "en": "Tie"},
	"duel.result.capture": {"zh": "你赢得了决斗,敌船投降!", "en": "You win the duel — the enemy ship strikes her colours!"},
	"duel.result.defeat": {"zh": "你输掉了决斗,舰船被夺。", "en": "You lose the duel and your ship is taken."},
	"duel.committed": {"zh": "接舷战无法撤退。", "en": "Boarding commits — there is no retreat."},
	"encounter.pirate": {"zh": "海盗船队", "en": "Pirate fleet"},
	"encounter.navy": {"zh": "{nation} 巡逻队", "en": "{nation} patrol"},
	"encounter.contact": {"zh": "{fleet} 逼近!", "en": "{fleet} closes in!"},
	"encounter.attack_confirm": {"zh": "攻击{nation}船队即是海盗行为(声望 −20)。确定吗?", "en": "Attacking a {nation} fleet is an act of piracy (−20 reputation). Continue?"},
	"gameover.captured": {"zh": "你被俘了,船队落入敌手。", "en": "Captured — your fleet is lost to the enemy."},
}


## True when [constant DOC_STRINGS] carries `key`.
static func has(key: String) -> bool:
	return DOC_STRINGS.has(key)


## The §4.12.5 L10nString for `key` (`{}` when this bridge does not cover it).
static func get_string(key: String) -> Dictionary:
	var l10n = DOC_STRINGS.get(key, {})
	return l10n if l10n is Dictionary else {}
