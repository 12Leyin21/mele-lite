"""塔罗牌义表（10-03）：78 张 × 中英，正逆位各一句核心意思 + 三四个关键词。

**全部是我们自己写的话**，没照任何书、网站或现成提示词的原文。
解牌时只把抽中那几张的 entry_line 递给模型，剩下的展开靠模型自己懂塔罗；牌局页牌下的小标签也从这里取。
key 用英文，跟 iOS 牌面图资源名一一对应。"""
from __future__ import annotations

_SUITS = (("wands", "权杖", "Wands"), ("cups", "圣杯", "Cups"), ("swords", "宝剑", "Swords"),
          ("pentacles", "星币", "Pentacles"))
_RANKS = (("01", "王牌", "Ace"), ("02", "二", "Two"), ("03", "三", "Three"), ("04", "四", "Four"),
          ("05", "五", "Five"), ("06", "六", "Six"), ("07", "七", "Seven"), ("08", "八", "Eight"),
          ("09", "九", "Nine"), ("10", "十", "Ten"), ("page", "侍从", "Page"), ("knight", "骑士", "Knight"),
          ("queen", "王后", "Queen"), ("king", "国王", "King"))
_MAJOR = ("愚人|The Fool", "魔术师|The Magician", "女祭司|The High Priestess", "皇后|The Empress",
          "皇帝|The Emperor", "教皇|The Hierophant", "恋人|The Lovers", "战车|The Chariot", "力量|Strength",
          "隐士|The Hermit", "命运之轮|Wheel of Fortune", "正义|Justice", "倒吊人|The Hanged Man", "死神|Death",
          "节制|Temperance", "恶魔|The Devil", "高塔|The Tower", "星星|The Star", "月亮|The Moon", "太阳|The Sun",
          "审判|Judgement", "世界|The World")

CARDS: list[str] = [f"major_{i:02d}" for i in range(22)] + [f"{s}_{r}" for s, _, _ in _SUITS for r, _, _ in _RANKS]

# 每张四行：中文正位 / 中文逆位 / 英文正位 / 英文逆位；「核心｜关键词、关键词」，英文用「 | 」和「, 」。
_TEXT = """
major_00
不带地图就出发，相信下一步自己会知道｜新的开始、天真、冒险、自由
冲动没看路，或怕摔所以一直不迈步｜鲁莽、犹豫、不设防、原地打转
Setting out without a map, trusting the next step will show itself | new start, innocence, leap, freedom
Leaping without looking — or never leaping for fear of falling | recklessness, hesitation, naivety, stalling
major_01
手边的东西已经够了，现在就动手把想法做出来｜行动、专注、资源、意志
本事没用对地方，或说得多做得少｜空谈、分心、操纵、虚张声势
The tools are already in hand; turn the idea into something real now | action, focus, resourcefulness, will
Skill pointed the wrong way, or more talk than doing | empty talk, scattered, manipulation, bluff
major_02
答案不在外面，安静下来听自己心里那个声音｜直觉、沉默、秘密、内在
不肯听自己的直觉，或有事被藏着没说｜忽视直觉、隐瞒、心乱、隔阂
The answer isn't out there; go quiet and listen inward | intuition, stillness, mystery, inner knowing
Ignoring your gut, or something kept hidden | doubt, secrets, noise, disconnection
major_03
被滋养也去滋养，让事情慢慢长出来｜丰盛、照顾、感官、孕育
把自己掏空去照顾别人，或照顾得太紧｜透支、过度保护、停滞、忽视自己
Nourish and be nourished; let things grow at their own pace | abundance, care, senses, growth
Pouring yourself out for others, or smothering | depletion, overprotection, stagnation, neglecting self
major_04
定规矩、担责任，用结构把局面稳住｜秩序、权威、边界、稳定
控制过头变成僵硬，或者该立的规矩没立｜专断、僵化、失序、缺乏纪律
Set the rules, carry the weight, hold things steady with structure | order, authority, boundaries, stability
Control turned rigid, or no structure where it's needed | domineering, rigidity, chaos, lack of discipline
major_05
走前人走过的路，向传统、老师或群体学｜传统、学习、信念、归属
不想再照别人的规矩活，要找自己的路｜反叛、质疑、教条、另辟蹊径
Walk a tested path — learn from tradition, a teacher, a community | tradition, learning, belief, belonging
Done living by others' rules; looking for your own way | rebellion, questioning, dogma, unconventional
major_06
一个出于真心的选择，两边心意相合｜爱、选择、契合、价值观
心和行动不一致，或关系里失了平衡｜失衡、诱惑、犹豫、价值冲突
A choice made from the heart; two sides in alignment | love, choice, harmony, values
Heart and actions don't match, or a bond out of balance | imbalance, temptation, indecision, misalignment
major_07
把拉向两边的力收拢，朝一个方向冲｜意志、胜利、掌控、前进
方向乱了，或只顾往前冲不看路｜失控、分散、受阻、急躁
Rein in the forces pulling apart and drive in one direction | willpower, victory, control, momentum
Lost direction, or charging ahead without steering | loss of control, scattered, blocked, aggression
major_08
用温柔驯服猛兽，耐心比硬来更有力｜勇气、耐心、温柔、自持
对自己没信心，或情绪压不住｜自我怀疑、脆弱、失控、压抑
Taming the lion gently — patience is stronger than force | courage, patience, compassion, self-control
Low self-belief, or feelings boiling over | self-doubt, fragility, outbursts, suppression
major_09
暂时退一步，一个人提灯找答案｜独处、内省、寻找、指引
独处变成了躲，或者太久没跟人说话｜孤立、逃避、迷失、封闭
Step back for a while and carry your own lamp | solitude, reflection, searching, inner guidance
Solitude turned into hiding, or alone for too long | isolation, withdrawal, lost, shut off
major_10
轮子在转，局面要变了，顺势而为｜转机、周期、命运、变化
运势低一点，或硬抓着不想让它变｜低潮、抗拒变化、反复、身不由己
The wheel turns; things are shifting — move with it | turning point, cycles, fate, change
A downswing, or clinging to keep things from changing | bad luck, resisting change, repetition, out of your hands
major_11
有因就有果，看清事实，公平地做决定｜公平、真相、因果、责任
有失公允，或不肯面对自己那份责任｜不公、逃避责任、偏见、失衡
Cause and effect — see the facts clearly and decide fairly | fairness, truth, accountability, consequence
Something unfair, or dodging your own part | injustice, avoidance, bias, dishonesty
major_12
停下来，换个角度看，等待有它的意义｜暂停、换角度、放下、牺牲
拖着不动，或白白牺牲｜拖延、僵局、无谓牺牲、执拗
Pause and turn the picture upside down; the waiting means something | pause, new perspective, surrender, sacrifice
Stalling, or giving things up for nothing | delay, stalemate, martyrdom, stubbornness
major_13
一段结束了，腾出地方给新的东西｜结束、转变、告别、重生
该结束的拖着不放，害怕改变｜抗拒、拖延、停滞、怕变
Something ends to make room for what comes next | ending, transformation, letting go, renewal
Holding on to what's already over | resistance, lingering, stagnation, fear of change
major_14
不急不躁，把两样东西慢慢调和到刚好｜平衡、节制、调和、耐心
失了分寸，走极端或太急｜过度、失衡、急躁、不协调
Unhurried, blending two things until they're just right | balance, moderation, harmony, patience
Lost measure — extremes or haste | excess, imbalance, impatience, discord
major_15
被某样东西绑住了，而锁其实没扣死｜束缚、欲望、执念、依赖
开始挣开，看清了绑住自己的是什么｜解脱、觉察、戒断、夺回主动
Chained to something — though the lock isn't really closed | bondage, desire, attachment, addiction
Starting to break free, seeing what held you | release, awareness, detachment, reclaiming power
major_16
突然的震动把不牢的东西震塌，真相露出来｜剧变、崩塌、觉醒、真相
躲过一劫，或该来的变化被一直压着｜侥幸、迟来的崩塌、内在动荡、余震
A sudden jolt brings down what was unsound and shows the truth | upheaval, collapse, revelation, awakening
A narrow escape, or a needed change held back | averted disaster, delayed collapse, inner turmoil, aftershock
major_17
风暴过后，伤口在愈合，可以重新相信｜希望、疗愈、平静、信心
一时看不到希望，对自己没信心｜失望、灰心、断联、信心不足
After the storm, healing begins; you can believe again | hope, healing, serenity, renewal
Hope feels far off; faith in yourself runs low | discouragement, despair, disconnection, doubt
major_18
看不清的时候，别被想象出来的害怕带着走｜不安、迷雾、潜意识、幻象
雾在散，误会解开，看清了真相｜澄清、释放恐惧、真相浮现、走出困惑
When things are unclear, don't let imagined fears lead | uncertainty, illusion, subconscious, anxiety
The fog lifts; a misunderstanding clears up | clarity, releasing fear, truth surfacing, confusion ending
major_19
明亮、简单、开心，事情朝好的方向走｜快乐、成功、温暖、坦率
开心打了点折扣，或者乐观过头｜小挫折、延迟、过度乐观、暂时阴天
Bright, simple, glad — things are going well | joy, success, warmth, vitality
Joy dimmed a little, or optimism stretched too far | minor setback, delay, overconfidence, clouded
major_20
听见召唤，回头看清自己，然后重新出发｜觉醒、反省、召唤、重生
对自己太苛刻，或听见了却不肯回应｜自我否定、逃避召唤、犹豫、悔恨
Hearing the call, looking back honestly, rising again | awakening, reckoning, calling, renewal
Judging yourself too harshly, or ignoring the call | self-doubt, avoidance, hesitation, regret
major_21
一段路走完了，圆满收尾，准备下一段｜完成、圆满、整合、抵达
差最后一步，或迟迟不肯收尾｜未完成、缺口、拖延收尾、停滞
A journey complete, a circle closed, ready for the next | completion, wholeness, integration, arrival
One step short, or not letting yourself finish | incomplete, loose ends, delay, lack of closure
wands_01
一股新的热情冒出来，想做就开始｜灵感、热情、开端、冲劲
火点不着，或冲劲来得快去得快｜拖延、没动力、三分钟热度、受阻
A new spark — if you want to do it, begin | inspiration, passion, new venture, energy
The spark won't catch, or burns out fast | delay, low drive, false start, blocked
wands_02
站在高处看远方，计划下一步往哪走｜计划、远见、抉择、走出舒适区
计划停在纸上，怕走出熟悉的地方｜犹豫、怕未知、规划不足、原地踏步
Looking out from the walls, planning where to go next | planning, vision, decision, leaving comfort
Plans stuck on paper; afraid of the unfamiliar | hesitation, fear of unknown, poor planning, staying put
wands_03
船已经放出去了，等它们回来，视野变宽｜展望、扩张、等待成果、远方
进展比想的慢，或计划没想周全｜延误、受挫、目光短浅、意外阻碍
Ships sent out; watching for their return, horizon widening | expansion, foresight, progress, distance
Slower than hoped, or plans not thought through | delays, frustration, short-sighted, obstacles
wands_04
有个值得庆祝的落脚处，跟人一起开心｜庆祝、安稳、家、团聚
家里或团体里不太和谐，庆祝打了折｜不安定、摩擦、过渡期、缺归属
A place worth celebrating, joy shared with others | celebration, home, stability, togetherness
Friction at home or in the group; the party's muted | instability, conflict, transition, not belonging
wands_05
大家都在争，乱成一团，但也是在练手｜竞争、冲突、分歧、较劲
退出无谓的争吵，或冲突转到暗处｜回避冲突、和解、内耗、压着火
Everyone clashing at once — messy, but it sharpens you | competition, conflict, disagreement, rivalry
Stepping out of pointless fights, or conflict going underground | avoidance, truce, inner conflict, suppressed tension
wands_06
赢了，被人看见、被人称赞｜胜利、认可、自信、凯旋
被忽视，或太在意别人的掌声｜不被认可、自负、跌落、患得患失
A win, and being seen and praised for it | victory, recognition, confidence, success
Overlooked, or hungry for applause | no recognition, ego, fall from grace, insecurity
wands_07
站在高处守住自己的立场，不退｜坚守、防御、立场、勇气
守累了想放弃，或被压得招架不住｜疲于应付、退让、被压倒、自我怀疑
Holding the high ground, not backing down | defence, standing firm, conviction, courage
Worn out from defending, or overwhelmed | exhaustion, giving up, overwhelmed, doubt
wands_08
事情一下子快起来，消息、进展接连到｜迅速、进展、消息、顺畅
被拖住了，或节奏乱成一团｜延迟、仓促、混乱、错过时机
Things suddenly move fast — news and progress arriving | speed, movement, news, momentum
Held up, or rushing into a muddle | delays, haste, chaos, bad timing
wands_09
伤痕累累但还站着，再撑一下就到了｜坚持、防备、韧性、最后一关
撑不住了，或防备心重到推开所有人｜筋疲力尽、多疑、放弃、固执
Battered but still standing; one last push | resilience, persistence, guardedness, last stretch
Can't hold on, or so guarded it pushes everyone away | exhaustion, paranoia, giving up, stubbornness
wands_10
背的东西太多了，压得看不见前面的路｜重担、责任、压力、过劳
开始放下一些，或者硬扛到快崩｜卸担子、分担、崩溃边缘、学会拒绝
Carrying too much to see the road ahead | burden, responsibility, stress, overwork
Starting to put some down, or about to break | releasing load, delegating, breaking point, saying no
wands_page
好奇、想试，一个让人兴奋的新点子来了｜好奇、探索、新消息、热情
点子多但都没下文，或冒冒失失｜三分钟热度、拖延、冒失、坏消息
Curious and eager — an exciting idea arrives | curiosity, exploration, news, enthusiasm
Lots of ideas, none followed through; or brash | short-lived, procrastination, impulsiveness, setbacks
wands_knight
说走就走，带着一股热劲往前冲｜冒险、冲劲、行动、魅力
冲得太猛，脾气急，事情做一半｜鲁莽、急躁、半途而废、浮躁
Off at a gallop, all fire and forward motion | adventure, energy, action, charm
Too fast, too hot-headed, leaving things half done | recklessness, impatience, unfinished, restless
wands_queen
自信、热情、有感染力，自己就是光｜自信、热情、独立、魅力
心里没底，或热情变成了嫉妒和逞强｜不自信、嫉妒、强势、透支
Confident, warm, magnetic — her own light | confidence, warmth, independence, charisma
Shaky inside, or fire turned to jealousy and bluster | insecurity, jealousy, demanding, burnout
wands_king
有远见也有魄力，能带着别人往前走｜领导、远见、魄力、担当
霸道、急躁，要求别人都跟上自己｜专横、冲动、傲慢、期望过高
Vision and nerve; able to lead others forward | leadership, vision, boldness, responsibility
Overbearing, impatient, demanding everyone keep up | domineering, impulsive, arrogant, unrealistic expectations
cups_01
心里满出来的一份感情，新的爱或新的感动｜爱、感动、敞开、新感情
感情憋着出不来，或心里空落落｜压抑、心门紧闭、空虚、情绪阻塞
Feeling overflowing — new love, new tenderness | love, compassion, openness, new feelings
Feelings bottled up, or an empty cup | repression, closed heart, emptiness, blocked emotion
cups_02
两个人互相看见，彼此回应｜结合、互相吸引、伙伴、和解
两人之间失了平衡，或闹了别扭｜失衡、疏远、误会、分歧
Two people seeing each other and answering in kind | partnership, attraction, mutuality, reconciliation
The bond tilts, or a falling-out | imbalance, distance, misunderstanding, tension
cups_03
跟好朋友一起举杯，热闹、有人陪｜友谊、庆祝、聚会、陪伴
玩过头了，或朋友圈里起了摩擦｜放纵、小圈子、八卦、被落下
Raising a glass with friends — company and celebration | friendship, celebration, community, joy
Overindulging, or friction creeping into the circle | excess, gossip, cliques, feeling left out
cups_04
对眼前的提不起兴趣，没看见递过来的那杯｜倦怠、冷漠、沉思、错过
从冷淡里醒过来，愿意接受新东西了｜重新投入、觉察、接受、走出低落
Bored with what's here; not noticing the cup being offered | apathy, contemplation, discontent, missed chance
Waking from the slump, ready to take something new | re-engaging, awareness, acceptance, moving on
cups_05
盯着打翻的三杯难过，忘了身后还立着两杯｜失落、遗憾、悲伤、执着过去
慢慢接受了，转身看见还剩下的｜释怀、接受、走出来、原谅
Grieving three spilled cups, missing the two still standing | loss, regret, grief, dwelling
Coming to terms, turning to see what remains | acceptance, moving on, forgiveness, recovery
cups_06
想起小时候和旧日子，单纯的温暖｜怀旧、童年、纯真、旧人
活在过去出不来，或终于跟过去告别｜沉溺过去、不切实际、告别、长大
Memories of childhood and old days; simple warmth | nostalgia, childhood, innocence, old friends
Stuck in the past, or finally leaving it | living in the past, unrealistic, moving forward, growing up
cups_07
选项太多、幻想太多，看着都好但不一定是真的｜幻想、选择、诱惑、白日梦
雾散了，看清哪个才是真想要的｜看清、做决定、回到现实、专注
Too many choices and daydreams; not all of them are real | fantasy, options, illusion, wishful thinking
The haze clears; you see what you actually want | clarity, decision, reality check, focus
cups_08
转身离开，那里已经满足不了你了｜离开、寻找、放下、更深的需要
想走又不敢走，或走来走去在逃｜犹豫、怕改变、逃避、留恋
Walking away from what no longer fills you | departure, seeking, letting go, deeper meaning
Wanting to leave but afraid to, or drifting from place to place | hesitation, fear of change, avoidance, clinging
cups_09
心愿实现了，满足地享受一下｜满足、心愿成真、享受、得意
得到了却没那么开心，或享受过头｜不满足、空虚、放纵、自满
The wish came true; enjoy it | contentment, wish fulfilled, pleasure, satisfaction
Got it but not as happy as expected, or overindulging | dissatisfaction, hollowness, excess, smugness
cups_10
家里和睦、爱的人都在身边，心安｜圆满、家庭、和睦、归属
表面和气底下有裂缝，或对家的期望落空｜家庭矛盾、失望、疏离、理想破灭
A peaceful home, the people you love all close | harmony, family, fulfilment, belonging
Cracks under the calm, or a family ideal let down | family conflict, disappointment, disconnection, broken ideals
cups_page
一点柔软的心意，一个让人心动的消息｜心动、灵感、温柔、好消息
情绪化、太敏感，或心意没传过去｜情绪化、幼稚、受伤、失望
A small tender gesture, a message that stirs the heart | sweetness, intuition, creativity, good news
Moody, oversensitive, or a feeling not getting across | immaturity, hurt feelings, moodiness, letdown
cups_knight
带着一颗真心来，浪漫、温柔地追｜浪漫、追求、邀约、理想主义
说得好听做得不多，或太活在幻想里｜不切实际、反复无常、甜言蜜语、失望
Arriving with an open heart — romantic, gentle pursuit | romance, invitation, charm, idealism
Sweet words, little follow-through; living in a fantasy | unrealistic, moody, empty promises, disappointment
cups_queen
能接住别人的情绪，也照顾得了自己的｜共情、温柔、直觉、包容
被别人的情绪淹没，忘了自己｜情绪透支、依赖、过度敏感、没有边界
Holding others' feelings while still tending her own | empathy, tenderness, intuition, acceptance
Drowning in others' emotions, forgetting herself | emotional burnout, dependence, oversensitivity, no boundaries
cups_king
情绪稳得住，温和又有分寸｜成熟、稳重、宽厚、情绪平衡
把情绪压着不说，或者被情绪左右｜压抑、冷淡、情绪操控、喜怒无常
Feelings steady, kind and measured | emotional maturity, calm, generosity, balance
Feelings locked away, or ruled by them | repression, coldness, manipulation, volatility
swords_01
一下子想通了，真相像刀一样清楚｜清晰、真相、突破、决断
想得乱，或话说得太锋利伤了人｜混乱、误判、伤人的话、思路堵塞
A sudden clear thought; the truth cuts clean | clarity, truth, breakthrough, decision
Muddled thinking, or words sharp enough to wound | confusion, misjudgement, harsh words, mental block
swords_02
蒙着眼不想选，两边僵着｜僵局、逃避、两难、暂时休战
不得不面对了，或信息太多更难选｜摘下眼罩、信息过载、焦虑、被迫决定
Blindfolded, refusing to choose; a standoff | stalemate, avoidance, indecision, truce
Forced to face it, or too much information to choose | facing it, overload, anxiety, pressured choice
swords_03
心被刺痛了，难过是真的，可以哭｜心碎、悲伤、伤痛、失望
伤在慢慢好，或把痛憋着不肯说｜疗伤、释怀、压抑悲伤、旧伤
The heart is pierced; the hurt is real and it's okay to cry | heartbreak, sorrow, grief, pain
Healing slowly, or holding the pain in | recovery, release, suppressed grief, old wounds
swords_04
停下来休息，养好了再上路｜休息、恢复、静养、暂停
歇不下来，或者休息够了该动了｜焦躁、硬撑、重新出发、失眠
Lie down and rest; recover before going on | rest, recovery, retreat, pause
Can't switch off, or rested enough to move again | restlessness, burnout, re-entering, sleeplessness
swords_05
赢了嘴仗却输了人，这种胜利值不值｜争执、输赢、代价、自私
和解，或者终于愿意放下这场争｜和解、放下、后悔、各退一步
Won the argument, lost the people — was it worth it? | conflict, hollow victory, cost, self-interest
Making peace, or finally letting the fight go | reconciliation, letting go, regret, compromise
swords_06
离开风浪，往平静一点的地方慢慢走｜过渡、离开、平静、疗愈
想走走不了，或带着旧包袱上路｜受困、抗拒离开、旧包袱、回头
Leaving rough water for somewhere calmer | transition, moving on, calmer waters, recovery
Stuck and unable to leave, or carrying old baggage along | stuck, resisting change, baggage, turning back
swords_07
偷偷摸摸绕开正面，有人没说实话｜隐瞒、策略、独行、取巧
被揭穿，或良心不安想坦白｜坦白、被发现、良心、不再取巧
Sneaking around, avoiding the front door; someone's not being straight | deception, strategy, going it alone, cunning
Caught out, or conscience pushing toward the truth | confession, exposure, conscience, coming clean
swords_08
被自己的想法困住，其实绳子是松的｜受困、限制、自我设限、无力感
意识到能走出来，开始解开束缚｜解脱、新视角、自由、重拾力量
Trapped by your own thoughts — the bindings are looser than they feel | restriction, self-limiting, helplessness, stuck
Realising you can walk out; loosening the ties | release, new perspective, freedom, regaining power
swords_09
半夜醒来想太多，焦虑比事情本身还大｜焦虑、失眠、担忧、自责
最坏的担心在退，或者焦虑到了顶点｜走出焦虑、求助、释怀、绝望顶点
Awake at night, the worry bigger than the thing itself | anxiety, insomnia, worry, guilt
The worst fears easing, or anxiety at its peak | relief, reaching out, letting go, despair peaking
swords_10
到底了，最坏的已经发生，接下来只会往上｜结束、谷底、痛苦、了结
从谷底慢慢起来，或不肯承认已经结束｜复原、劫后余生、拖着不结束、重生
Rock bottom — the worst has happened; up is the only way now | ending, rock bottom, pain, finality
Slowly getting up, or refusing to accept it's over | recovery, survival, dragging it out, regeneration
swords_page
好奇、警觉，想把事情弄个明白｜好奇、观察、求知、机敏
多嘴、说话不经脑，或光说不练｜八卦、冒失、空谈、多疑
Curious and alert, wanting to get to the bottom of it | curiosity, vigilance, learning, wit
Gossipy, speaking without thinking, all talk | gossip, hasty words, all talk, suspicion
swords_knight
想到就冲，直来直去，速度很快｜果断、直接、冲刺、雄心
冲得太快伤到人，或想法乱飞｜鲁莽、尖刻、冲动、横冲直撞
Charging on an idea — direct and very fast | decisiveness, directness, ambition, speed
Too fast and cutting, or thoughts flying everywhere | recklessness, sharp tongue, impulsive, scattered
swords_queen
看得清、说得直，温柔但不糊涂｜清醒、坦率、独立、明辨
话太冷太尖，或拿理智挡住伤心｜刻薄、冷漠、苦涩、封闭
Clear-eyed and plain-spoken; kind but not fooled | clarity, honesty, independence, discernment
Cold or cutting, or using logic to wall off hurt | harshness, coldness, bitterness, guardedness
swords_king
讲道理、有原则，用头脑做公正的判断｜理性、权威、公正、原则
冷冰冰地讲理，或用聪明压人｜冷酷、操纵、教条、滥用权力
Reasoned and principled; judging fairly with a clear head | intellect, authority, fairness, principle
Cold logic, or cleverness used to dominate | ruthlessness, manipulation, rigidity, abuse of power
pentacles_01
一个实实在在的新机会，钱、工作或身体上的｜新机会、财运、落地、种子
机会溜走，或计划不够踏实｜错失机会、财务不稳、规划不足、贪心
A real, tangible opportunity — money, work or body | opportunity, prosperity, grounding, seed
A chance slipping away, or plans not grounded | missed opportunity, instability, poor planning, greed
pentacles_02
几件事同时顾，一边接一边抛，还算稳｜平衡、兼顾、灵活、调度
顾不过来了，手忙脚乱｜失衡、分身乏术、财务混乱、过载
Juggling several things at once, and still keeping it up | balance, adaptability, juggling, priorities
Can't keep it all up; dropping things | overwhelm, imbalance, disorganised, overcommitted
pentacles_03
跟别人一起把事情做好，手艺被看见｜合作、手艺、团队、认可
配合不好，或敷衍了事｜不合作、敷衍、各自为政、质量差
Building something well with others; craft being noticed | teamwork, skill, collaboration, recognition
Poor teamwork, or cutting corners | disharmony, sloppiness, misalignment, mediocrity
pentacles_04
抓紧手里的东西，求稳求安全｜守财、安全感、控制、保守
抓得太紧放不开，或者花钱没节制｜吝啬、放手、挥霍、不安全感
Holding tight to what you have for security | saving, security, control, conservatism
Gripping too hard, or spending with no restraint | stinginess, letting go, overspending, insecurity
pentacles_05
又冷又缺，觉得被关在外面，亮灯的门就在旁边｜困难、匮乏、孤立、担忧
难关在过去，开始接受帮助｜复苏、求助、好转、找回信心
Cold and short, feeling shut out — though a lit door is right there | hardship, scarcity, isolation, worry
The hard stretch passing; accepting help | recovery, asking for help, improvement, hope returning
pentacles_06
给出去也接得住，资源在流动｜给予、接受、慷慨、互助
给和拿不对等，带着条件的好｜不对等、附带条件、亏欠、施舍感
Giving and receiving; resources flowing | generosity, charity, sharing, support
Give and take out of balance; help with strings | inequality, strings attached, debt, power imbalance
pentacles_07
种下的还没熟，停下来看看值不值得继续｜耐心、评估、长期投入、等待
心急想马上看到结果，或投入了没回报｜急躁、白费力、半途而废、回报不足
The crop isn't ripe yet; pause and judge if it's worth tending | patience, assessment, long-term effort, waiting
Wanting results now, or effort with no return | impatience, wasted effort, giving up, poor return
pentacles_08
低头一件件做，把手艺磨好｜专注、勤奋、精进、手艺
做得机械没心思，或追求完美停不下｜敷衍、倦怠、完美主义、方向不对
Head down, one piece at a time, honing the craft | diligence, focus, mastery, skill
Going through the motions, or perfectionism that won't stop | half-hearted, burnout, perfectionism, misdirected effort
pentacles_09
靠自己挣来的从容，一个人也过得很好｜独立、富足、自律、享受
为了表面撑着，或太依赖别人供养｜虚荣、过度工作、依赖、不安全感
Ease earned by your own hands; content on your own | independence, abundance, self-discipline, luxury
Keeping up appearances, or leaning too much on others | superficiality, overwork, dependence, insecurity
pentacles_10
长久的家底、一家人的安稳，能传下去的东西｜传承、家庭、财富、长久
家里为钱起了争执，或根基不稳｜家庭纠纷、遗产问题、不稳定、短视
Lasting wealth and family security; something to pass on | legacy, family, wealth, permanence
Family quarrels over money, or shaky foundations | family disputes, inheritance trouble, instability, short-term thinking
pentacles_page
认真想学点实在的东西，一步步来｜学习、踏实、新计划、机会
想得多做得少，或者学不进去｜拖延、懒散、目标模糊、没进展
Keen to learn something practical, one step at a time | study, diligence, new plan, opportunity
More planning than doing, or can't focus | procrastination, laziness, unclear goals, lack of progress
pentacles_knight
慢但稳，一步一步把事做完｜可靠、耐心、勤恳、负责
慢到停住，或闷头死做不知变通｜停滞、无聊、固执、过度谨慎
Slow but steady, seeing the job through | reliability, patience, hard work, routine
So slow it stops, or plodding without adapting | stagnation, boredom, stubbornness, over-caution
pentacles_queen
把日子照顾得踏实温暖，务实又会心疼人｜务实、照顾、富足、踏实
只顾着照顾别人或工作，忘了自己｜失衡、过度操劳、忽视自己、钱的焦虑
Making daily life warm and solid; practical and caring | nurturing, practicality, abundance, groundedness
Tending everyone and everything but herself | imbalance, overwork, self-neglect, money worries
pentacles_king
稳、富足、靠得住，把事业经营得好｜成功、稳定、富足、可靠
太看重钱和面子，或固执守旧｜贪婪、物质主义、固执、控制
Steady, prosperous, dependable; runs things well | success, stability, wealth, reliability
Too focused on money and status, or stuck in old ways | greed, materialism, stubbornness, control
"""


def _parse() -> dict:
    lines = [l.strip() for l in _TEXT.strip().splitlines() if l.strip()]
    out = {}
    for i in range(0, len(lines), 5):
        key, zu, zr, eu, er = lines[i:i + 5]
        zh = lambda s: (lambda c, k: {"core": c, "keywords": k.split("、")})(*s.split("｜"))
        en = lambda s: (lambda c, k: {"core": c, "keywords": k.split(", ")})(*s.rsplit(" | ", 1))
        out[key] = {"zh": {"upright": zh(zu), "reversed": zh(zr)}, "en": {"upright": en(eu), "reversed": en(er)}}
    return out


def _names() -> dict:
    out = {f"major_{i:02d}": dict(zip(("zh", "en"), n.split("|"))) for i, n in enumerate(_MAJOR)}
    for s, sz, se in _SUITS:
        for r, rz, re_ in _RANKS:
            out[f"{s}_{r}"] = {"zh": f"{sz}{rz}", "en": f"{re_} of {se}"}
    return out


_DATA, _NAME = _parse(), _names()


def name(key: str, lang: str) -> str:
    return _NAME[key][lang]


def card(key: str, lang: str) -> dict:
    return {"key": key, "name": _NAME[key][lang], **_DATA[key][lang]}


def entry_line(key: str, reversed: bool, lang: str) -> str:
    side = _DATA[key][lang]["reversed" if reversed else "upright"]
    if lang == "zh":
        return f"{_NAME[key]['zh']}（{'逆位' if reversed else '正位'}）：{side['core']}｜关键词：{'、'.join(side['keywords'])}"
    return f"{_NAME[key]['en']} ({'reversed' if reversed else 'upright'}): {side['core']} | keywords: {', '.join(side['keywords'])}"


def public(lang: str) -> list[dict]:
    """牌局页牌下的小标签用：名字 + 正逆位关键词（core 不给手机，那是喂模型的）。"""
    return [{"key": k, "name": _NAME[k][lang], "upright": _DATA[k][lang]["upright"]["keywords"],
             "reversed": _DATA[k][lang]["reversed"]["keywords"]} for k in CARDS]
