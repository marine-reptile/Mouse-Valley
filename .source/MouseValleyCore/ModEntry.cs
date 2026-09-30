using System;
using HarmonyLib;
using StardewModdingAPI;
using StardewValley;
using StardewValley.Delegates;
using StardewValley.Triggers;

namespace MouseValleyCore
{
    /// <summary>
    /// 老鼠的好感度不是原版意义上的好感度，而是任务进度的标记值：
    /// 对话、送礼、每日衰减、弹弓等一切走 Farmer.changeFriendship 的途径都不会改变它，
    /// 只能由 CP 的事件或触发动作调用 SetMouseHearts 设定。
    /// </summary>
    internal sealed class ModEntry : Mod
    {
        /// <summary>在 Data/Characters 的 CustomFields 里设为 "true" 的 NPC 会被锁定好感度。</summary>
        internal const string LockedField = "marinereptile.Mouse_Valley_Core/FriendshipLocked";

        private static IMonitor ModMonitor = null!;

        public override void Entry(IModHelper helper)
        {
            ModMonitor = this.Monitor;

            var harmony = new Harmony(this.ModManifest.UniqueID);
            harmony.Patch(
                original: AccessTools.Method(typeof(Farmer), nameof(Farmer.changeFriendship), new[] { typeof(int), typeof(NPC) }),
                prefix: new HarmonyMethod(typeof(ModEntry), nameof(Before_ChangeFriendship))
            );

            // 用法：marinereptile.Mouse_Valley_Core_SetMouseHearts <NPC 内部名> <心数>
            TriggerActionManager.RegisterAction($"{this.ModManifest.UniqueID}_SetMouseHearts", SetMouseHearts);
        }

        internal static bool IsLocked(string? name)
        {
            return name != null
                && Game1.characterData.TryGetValue(name, out var data)
                && data.CustomFields?.TryGetValue(LockedField, out string? value) == true
                && bool.TryParse(value, out bool locked)
                && locked;
        }

        /// <summary>锁定的 NPC 直接跳过原方法，好感度不变。</summary>
        private static bool Before_ChangeFriendship(NPC __1)
        {
            return __1 is null || !IsLocked(__1.Name);
        }

        private static bool SetMouseHearts(string[] args, TriggerActionContext context, out string error)
        {
            if (!ArgUtility.TryGet(args, 1, out string npcName, out error, allowBlank: false, name: "string npcName")
                || !ArgUtility.TryGetInt(args, 2, out int hearts, out error, name: "int hearts"))
                return false;

            if (!IsLocked(npcName))
            {
                error = $"NPC '{npcName}' 没有设置 {LockedField}，不能用这个动作修改好感度";
                return false;
            }

            hearts = Math.Clamp(hearts, 0, 10);
            Farmer player = Game1.player;
            if (!player.friendshipData.TryGetValue(npcName, out Friendship friendship))
            {
                friendship = new Friendship();
                player.friendshipData[npcName] = friendship;
            }

            friendship.Points = hearts * NPC.friendshipPointsPerHeartLevel;
            ModMonitor.Log($"{npcName} 的好感度设为 {hearts} 心", LogLevel.Trace);
            return true;
        }
    }
}
