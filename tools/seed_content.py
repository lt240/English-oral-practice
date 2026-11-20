# -*- coding: utf-8 -*-
"""
生成 assets/content/ 内容源（index.json + <id>.json）。

文稿来源说明：
- matt_cutts_30_days.json 保留原有「精确句级时间戳 + 手写复述 clips」，
  本脚本只给它补元数据字段，绝不重写 sentences/clips。
- 其余带文稿的篇目，英文句子取自 TED 官方公开逐字稿（见 SOURCES），
  中文为对照翻译；时间戳按词数加权估算，标注 timingSource=estimated。
- 仅音频篇目：音频、主题、封面、讨论问题齐全，文稿标注待补，
  App 内可完整聆听，跟读/复述入口会给出明确提示。

重新生成：py -3 tools/seed_content.py && dart run tools/build_content.dart
"""
import json
import os
import re

from two_talks_data import BREWER, ROBBINS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "assets", "content")
MANIFEST = os.path.join(CONTENT, "media_manifest.json")

SOURCES = {
    "meg_jay": "TED 2013 / ted.com transcript",
    "levitin": "TED 2015 / ted.com transcript",
    "esfahani_smith": "TED 2017 / ted.com transcript",
    "brewer": "TEDMED 2015 / drjud.com 官方逐字稿",
    "robbins": "TEDxSF 2011 / TEDx Talks 官方逐字稿",
}


def S(en, zh):
    return (en, zh)


# ── 真实逐字稿节选（英文原句 + 中文对照）──────────────────────
MEG_JAY = [
    S("When I was in my 20s, I saw my very first psychotherapy client.", "我二十多岁时，接待了第一位心理治疗来访者。"),
    S("I was a Ph.D. student in clinical psychology at Berkeley.", "当时我在伯克利读临床心理学博士。"),
    S("She was a 26-year-old woman named Alex.", "她是一位 26 岁的女性，名叫 Alex。"),
    S("Now Alex walked into her first session wearing jeans and a big slouchy top, and she dropped onto the couch in my office and kicked off her flats.", "第一次咨询时，Alex 穿着牛仔裤和宽大的上衣走进来，一屁股坐进我办公室的沙发，踢掉了平底鞋。"),
    S("And she told me she was there to talk about guy problems.", "她说她来是想聊聊感情问题。"),
    S("Now when I heard this, I was so relieved.", "听到这话，我松了一口气。"),
    S("My classmate got an arsonist for her first client.", "我同学的第一个来访者是个纵火犯。"),
    S("And I got a twentysomething who wanted to talk about boys.", "而我的来访者只是个想聊男生的二十多岁女孩。"),
    S("This I thought I could handle. But I didn't handle it.", "我心想这我能应付，可我并没应付好。"),
    S("Thirty's the new 20, Alex would say, and as far as I could tell, she was right.", "Alex 常说「三十岁是新的二十岁」，而在我看来，她说得没错。"),
    S("Work happened later, marriage happened later, kids happened later, even death happened later.", "工作可以晚点，结婚可以晚点，生孩子可以晚点，连死亡都还早。"),
    S("Twentysomethings like Alex and I had nothing but time.", "像 Alex 和我这样的二十多岁的人，别的没有，就是有时间。"),
    S("But before long, my supervisor pushed me to push Alex about her love life.", "但没过多久，我的督导就催我追问 Alex 的感情生活。"),
    S("I pushed back. I said, sure, she's dating down, but it's not like she's going to marry the guy.", "我反驳说：没错，她交往的对象配不上她，可她又不打算嫁给他。"),
    S("And then my supervisor said, not yet, but she might marry the next one.", "督导回答说：现在还没有，但她可能会嫁给下一个。"),
    S("Besides, the best time to work on Alex's marriage is before she has one.", "而且，经营一段婚姻最好的时机，是在她还没有婚姻的时候。"),
    S("That's what psychologists call an Aha! moment.", "这就是心理学家所说的「顿悟时刻」。"),
    S("That was the moment I realized, 30 is not the new 20.", "就在那一刻我意识到：三十岁不是新的二十岁。"),
    S("Yes, people settle down later than they used to, but that didn't make Alex's 20s a developmental downtime.", "没错，人们比以前更晚安定下来，但这并不意味着二十多岁是发展的停滞期。"),
    S("That made Alex's 20s a developmental sweet spot, and we were sitting there blowing it.", "恰恰相反，那是发展的黄金期，而我们却坐视它白白流失。"),
    S("There are 50 million twentysomethings in the United States right now.", "如今美国有五千万二十多岁的年轻人。"),
    S("We're talking about 15 percent of the population, or 100 percent if you consider that no one's getting through adulthood without going through their 20s first.", "这约占总人口的 15%，换个角度说是 100%——因为没人能不经过二十多岁就进入成年。"),
    S("So I specialize in twentysomethings because I believe that every single one deserves to know what psychologists and sociologists already know.", "我专门研究二十多岁的年轻人，因为我坚信他们每个人都该知道心理学家和社会学家早已明白的事。"),
    S("That claiming your 20s is one of the simplest, yet most transformative, things you can do for work, for love, for your happiness.", "把握住二十多岁，是你能为事业、爱情和幸福做的最简单、也最具改变力的事之一。"),
    S("This is not my opinion. These are the facts.", "这不是我的观点，这是事实。"),
    S("We know that 80 percent of life's most defining moments take place by age 35.", "我们知道，人生中 80% 最具决定性的时刻发生在 35 岁之前。"),
    S("We know that the first 10 years of a career has an exponential impact on how much money you're going to earn.", "我们知道，职业生涯的头十年对你未来的收入有指数级影响。"),
    S("We know that more than half of Americans are married or are living with or dating their future partner by 30.", "我们知道，超过半数美国人在 30 岁前已结婚，或与未来的伴侣同居、交往。"),
    S("We know that the brain caps off its second and last growth spurt in your 20s as it rewires itself for adulthood.", "我们知道，大脑在二十多岁完成第二次也是最后一次发育冲刺，为成年期重新布线。"),
    S("Which means that whatever it is you want to change about yourself, now is the time to change it.", "这意味着，无论你想改变自己的哪一点，现在就是最好的时机。"),
    S("We know that personality changes more during your 20s than at any other time in life.", "我们知道，性格在二十多岁的变化幅度超过人生任何其他阶段。"),
    S("So when we think about child development, we all know that the first five years are a critical period.", "谈到儿童发展，我们都知道最初五年是关键期。"),
    S("But what we hear less about is that there's such a thing as adult development, and our 20s are that critical period.", "但我们很少听到：成年期同样有发展关键期，而二十多岁正是这个关键期。"),
    S("As a culture, we have trivialized what is actually the defining decade of adulthood.", "我们的文化把本是成年期决定性十年的一段时间，轻描淡写地打发了。"),
    S("Leonard Bernstein said that to achieve great things, you need a plan and not quite enough time.", "伦纳德·伯恩斯坦说过：要成就大事，你需要一个计划，以及不那么够用的时间。"),
    S("So what do you think happens when you pat a twentysomething on the head and say, you have 10 extra years to start your life?", "那么，当你拍拍一个二十多岁年轻人的头说「你还有十年慢慢开始人生」，会发生什么？"),
    S("You have robbed that person of his urgency and ambition, and absolutely nothing happens.", "你夺走了他的紧迫感与雄心，结果什么也不会发生。"),
    S("So get some identity capital.", "所以，去积累一些「身份资本」。"),
    S("Identity capital means doing something that adds value to who you are.", "身份资本，指的是去做那些能为你这个人增值的事。"),
    S("Twenty-somethings are like airplanes just taking off, heading for somewhere west.", "二十多岁的人就像刚刚起飞、向西而行的飞机。"),
    S("A slight change in course on takeoff is the difference between landing in Alaska or Fiji.", "起飞时航向的一点点偏差，最终决定你落在阿拉斯加还是斐济。"),
    S("You can pick your family, and you're going to have to do it consciously.", "你可以选择自己的家人，而且必须有意识地去做。"),
    S("You're deciding your life right now.", "此刻，你正在决定自己的人生。"),
]

LEVITIN = [
    S("A few years ago, I broke into my own house.", "几年前，我闯进了自己家。"),
    S("I had just driven home, it was around midnight in the dead of Montreal winter.", "我刚开车回到家，那是蒙特利尔隆冬的午夜。"),
    S("I had been visiting my friend, Jeff, across town.", "此前我去城另一头拜访了朋友 Jeff。"),
    S("The thermometer on the front porch read minus 40 degrees.", "门廊上的温度计显示零下 40 度。"),
    S("And don't bother asking if that's Celsius or Fahrenheit, minus 40 is where the two scales meet.", "别问是摄氏还是华氏，零下 40 度正是两个刻度重合的地方。"),
    S("And as I stood on the front porch fumbling in my pockets, I found I didn't have my keys.", "我站在门廊上摸遍口袋，发现没带钥匙。"),
    S("In fact, I could see them through the window, lying on the dining room table where I had left them.", "透过窗户，我甚至能看见钥匙就放在餐桌上，正是我落下的地方。"),
    S("So I quickly ran around and tried all the other doors and windows, and they were locked tight.", "于是我绕着房子跑了一圈试遍门窗，全都锁得死死的。"),
    S("I thought about calling a locksmith, at least I had my cellphone, but at midnight, it could take a while.", "我想过叫开锁匠，至少手机还在，可半夜三更可能得等很久。"),
    S("I couldn't go back to my friend Jeff's house for the night because I had an early flight to Europe the next morning.", "我又不能回 Jeff 家过夜，因为第二天一早要飞欧洲。"),
    S("So, desperate and freezing cold, I found a large rock and I broke through the basement window.", "又急又冻之下，我找了块大石头砸开了地下室的窗户。"),
    S("Now, I'm a neuroscientist by training and I know a little bit about how the brain performs under stress.", "我本是神经科学家，多少知道大脑在压力下的表现。"),
    S("It releases cortisol that raises your heart rate, it modulates adrenaline levels and it clouds your thinking.", "它会释放皮质醇，加快心率、调节肾上腺素，并让思维变得混沌。"),
    S("My thinking was cloudy, but I didn't know it was cloudy because my thinking was cloudy.", "我的思维是混沌的，可我并不知道——因为思维本身就混沌了。"),
    S("And it wasn't until I got to the airport check-in counter that I realized I didn't have my passport.", "直到站在机场值机柜台前，我才发现自己没带护照。"),
    S("So I raced home in the snow and ice, got my passport, raced back to the airport.", "我在冰雪里赶回家拿护照，再赶回机场。"),
    S("I made it just in time, but they had given away my seat to someone else.", "总算赶上了，可座位已经给了别人。"),
    S("Well, I had a lot of time to think during those eight hours and no sleep.", "那八个小时里我有大把时间思考，而且一夜没睡。"),
    S("And I started wondering, are there things that I can do, systems that I can put into place, that will prevent bad things from happening?", "我开始想：有没有什么办法、什么机制，能提前防止坏事发生？"),
    S("Danny shared with me that he'd been practicing something called prospective hindsight.", "Danny 告诉我，他一直在实践一种叫「前瞻性后见之明」的方法。"),
    S("It's also called the pre-mortem.", "它还有个名字，叫「事前验尸」。"),
    S("Now, you all know what the postmortem is. Whenever there's a disaster, a team of experts come in and they try to figure out what went wrong.", "大家都知道「事后复盘」：一旦出了事故，专家团队进来弄清哪里出了错。"),
    S("Well, in the pre-mortem, you look ahead and you try to figure out all the things that could go wrong.", "而「事前验尸」是往前看，提前把所有可能出错的地方想清楚。"),
    S("And then you try to figure out what you can do to prevent those things from happening, or to minimize the damage.", "然后再想办法阻止这些事发生，或把损失降到最低。"),
    S("Around the home, designate a place for things that are easily lost.", "在家里，给容易丢的东西固定一个位置。"),
    S("There's a structure in the brain called the hippocampus, that evolved over tens of thousands of years, to keep track of the locations of important things.", "大脑里有个叫海马体的结构，经过数万年演化，专门记住重要物品的位置。"),
    S("It's the part of the brain that allows squirrels to find their nuts.", "正是这部分大脑，让松鼠能找到自己埋的坚果。"),
    S("So this is why we lose car keys and reading glasses and passports.", "这就是为什么我们总丢车钥匙、老花镜和护照。"),
    S("What about travel? Take a cell phone picture of your credit cards, your driver's license, your passport, mail it to yourself so it's in the cloud.", "出行呢？把信用卡、驾照、护照拍照发给自己，存到云端。"),
    S("Remember, when you're under stress, the brain releases cortisol.", "记住，压力之下大脑会释放皮质醇。"),
    S("Cortisol is toxic, and it causes cloudy thinking.", "皮质醇是有毒的，它会让思维变浑。"),
    S("So part of the practice of the pre-mortem is to recognize that under stress you're not going to be at your best.", "所以「事前验尸」的一部分，就是承认压力下你不会处于最佳状态。"),
    S("And perhaps no more stressful a situation than when you're confronted with a medical decision to make.", "而最让人有压力的情形之一，莫过于要做一个医疗决定。"),
    S("We all are going to fail now and then.", "我们每个人时不时都会失败。"),
    S("The idea is to think ahead to what those failures might be, to put systems in place that will help minimize the damage.", "核心在于提前想清楚可能在哪儿失败，并建立机制把损失降到最小。"),
    S("Getting back to that snowy night in Montreal, I had my contractor install a combination lock next to the door.", "回到蒙特利尔那个雪夜——回来后我让师傅在门边装了个密码锁盒。"),
    S("So I'm not completely organized, but I see organization as a gradual process, and I'm getting there.", "我还算不上井井有条，但我把整理看作渐进的过程，而且正在变好。"),
    S("Thank you very much.", "非常感谢。"),
]

ESFAHANI = [
    S("I used to think the whole purpose of life was pursuing happiness.", "我以前以为，人生的全部意义就是追求快乐。"),
    S("Everyone said the path to happiness was success, so I searched for that ideal job, that perfect boyfriend, that beautiful apartment.", "人人都说成功是通往快乐的路，于是我去寻找理想的工作、完美的伴侣、漂亮的公寓。"),
    S("But instead of ever feeling fulfilled, I felt anxious and adrift.", "可我非但没有感到满足，反而焦虑又漂泊无依。"),
    S("And I wasn't alone; my friends, they struggled with this, too.", "并非只有我这样，我的朋友们也同样挣扎。"),
    S("Eventually, I decided to go to graduate school for positive psychology to learn what truly makes people happy.", "最终我去读了积极心理学的研究生，想弄清究竟什么让人幸福。"),
    S("But what I discovered there changed my life.", "但我在那里的发现改变了我的人生。"),
    S("The data showed that chasing happiness can make people unhappy.", "数据显示，追逐快乐反而会让人不快乐。"),
    S("And what really struck me was this: the suicide rate has been rising around the world.", "真正震撼我的是：全球自杀率一直在上升。"),
    S("Even though life is getting objectively better by nearly every conceivable standard, more people feel hopeless, depressed and alone.", "尽管按几乎任何客观标准生活都在变好，却有更多人感到无望、沮丧和孤独。"),
    S("There's an emptiness gnawing away at people, and you don't have to be clinically depressed to feel it.", "有一种空虚在侵蚀人们，不必被临床诊断为抑郁也能感受到。"),
    S("Sooner or later, I think we all wonder: Is this all there is?", "迟早我们都会问自己：难道就只有这些吗？"),
    S("And according to the research, what predicts this despair is not a lack of happiness.", "研究表明，预示这种绝望的并不是缺少快乐。"),
    S("It's a lack of something else, a lack of having meaning in life.", "而是缺少另一样东西：缺少人生的意义。"),
    S("But that raised some questions for me. Is there more to life than being happy?", "这让我产生疑问：人生难道不只有快乐吗？"),
    S("And what's the difference between being happy and having meaning in life?", "活得快乐和活得有意义，究竟有什么不同？"),
    S("Many psychologists define happiness as a state of comfort and ease, feeling good in the moment.", "许多心理学家把快乐定义为舒适自在的状态：此刻感觉很好。"),
    S("Meaning, though, is deeper.", "而意义要更深一层。"),
    S("The renowned psychologist Martin Seligman says meaning comes from belonging to and serving something beyond yourself.", "著名心理学家马丁·塞利格曼说，意义来自归属于并服务于超越自身的事物。"),
    S("Our culture is obsessed with happiness, but I came to see that seeking meaning is the more fulfilling path.", "我们的文化痴迷于快乐，但我逐渐明白，追寻意义才是更令人满足的道路。"),
    S("And the studies show that people who have meaning in life, they're more resilient, they do better in school and at work, and they even live longer.", "研究显示，拥有人生意义的人适应力更强，在学业和工作中表现更好，甚至活得更久。"),
    S("To find out, I spent five years interviewing hundreds of people and reading through thousands of pages of psychology, neuroscience and philosophy.", "为了找到答案，我花了五年访谈数百人，读了数千页心理学、神经科学和哲学著作。"),
    S("Bringing it all together, I found that there are what I call four pillars of a meaningful life.", "把这些汇总起来，我发现了我称之为「有意义人生的四大支柱」的东西。"),
    S("The first pillar is belonging.", "第一根支柱是归属感。"),
    S("Belonging comes from being in relationships where you're valued for who you are intrinsically and where you value others as well.", "归属感来自这样的关系：你因其本身而被珍视，你也同样珍视他人。"),
    S("But some groups and relationships deliver a cheap form of belonging; you're valued for what you believe, for who you hate, not for who you are.", "但有些群体提供的是廉价的归属感：你被看重是因为你信什么、恨谁，而不是因为你是谁。"),
    S("True belonging springs from love. It lives in moments among individuals, and it's a choice.", "真正的归属感源自爱，存在于人与人之间的片刻里，而且它是一种选择。"),
    S("For many people, belonging is the most essential source of meaning, those bonds to family and friends.", "对许多人来说，归属感是意义最重要的来源，是那些与家人朋友的联结。"),
    S("For others, the key to meaning is the second pillar: purpose.", "对另一些人，意义的关键是第二根支柱：目标。"),
    S("Now, finding your purpose is not the same thing as finding that job that makes you happy.", "找到目标，并不等同于找到一份让你开心的工作。"),
    S("Purpose is less about what you want than about what you give.", "目标更多关乎你付出什么，而不是你想要什么。"),
    S("A hospital custodian told me her purpose is healing sick people.", "一位医院保洁员告诉我，她的目标是治愈病人。"),
    S("The key to purpose is using your strengths to serve others.", "目标的关键，是用自己的长处去服务他人。"),
    S("Purpose gives you something to live for, some why that drives you forward.", "目标给了你活下去的理由，一个推着你向前的「为什么」。"),
    S("The third pillar of meaning is also about stepping beyond yourself, but in a completely different way: transcendence.", "第三根支柱同样关乎超越自我，但方式截然不同：超然。"),
    S("Transcendent states are those rare moments when you're lifted above the hustle and bustle of daily life.", "超然状态是那些罕见的时刻，你被从日常的喧嚣中托举起来。"),
    S("Your sense of self fades away, and you feel connected to a higher reality.", "自我感渐渐消退，你感到与某种更高的实在相连。"),
    S("Now, the fourth pillar of meaning, I found, tends to surprise people. The fourth pillar is storytelling.", "第四根支柱往往让人意外，它是「讲故事」。"),
    S("Creating a narrative from the events of your life brings clarity. It helps you understand how you became you.", "把人生经历编织成叙事会带来清明，帮你理解自己如何成为今天的自己。"),
    S("People leading meaningful lives tend to tell stories about their lives defined by redemption, growth and love.", "活得有意义的人，往往用救赎、成长和爱来讲述自己的人生。"),
]


# ── 13 篇音频的元数据（中文主题 + 英文文字封面 + 讨论问题）──────
def media(i):
    with open(MANIFEST, encoding="utf-8") as f:
        return json.load(f)["media"][i - 1]


def meta(idx, sid, title, title_zh, topic_zh, speaker, level, difficulty,
         tags, colors, questions, transcript=None, source="",
         audio_override=None):
    m = media(idx)
    dur = m["durationSeconds"] or 600
    return {
        "sid": sid,
        "title": title,
        "titleZh": title_zh,
        "topicZh": topic_zh,
        "speaker": speaker,
        "level": level,
        "difficulty": difficulty,
        "tags": tags,
        "coverColors": colors,
        "topicQuestions": questions,
        "audioPath": m["asset"] if audio_override is None else audio_override,
        # 素材原名：用于把用户提供的逐字稿合集按文件名自动映射到篇目
        "sourceMedia": m["source"],
        "audioMissing": audio_override == "",
        "durationMs": int(dur * 1000),
        "source": source or "TED音频素材库",
        "sentences": transcript,
    }


def q(pair):
    return pair[0] + "｜" + pair[1]


# 每篇至少 3 个主题问题：听前预测 / 听中理解 / 听后表达
QUESTIONS = {
    "meg_jay": [q(("Why does the speaker say thirty is not the new twenty?", "为什么讲者说「30 岁不是新的 20 岁」？")),
                q(("What is identity capital and how can you build it?", "什么是「身份资本」，你会怎么积累？")),
                q(("What is one small change you want to make in your twenties?", "你想在自己的二十多岁做出哪一个微小改变？"))],
    "levitin": [q(("What went wrong on the night the speaker broke into his own house?", "讲者闯进自己家那晚，究竟哪里出了错？")),
                q(("What is a pre-mortem and how is it different from a postmortem?", "什么是「事前验尸」，它与事后复盘有何不同？")),
                q(("What system could you set up to prevent your own next mistake?", "你会建立什么机制，防止自己下一次犯错？"))],
    "esfahani": [q(("What is the difference between happiness and meaning?", "快乐与意义的区别是什么？")),
                 q(("Can you name the four pillars of a meaningful life?", "你能说出有意义人生的四根支柱吗？")),
                 q(("Which pillar matters most in your own life right now?", "当下哪根支柱对你最重要？"))],
    "habits": [q(("Why do bad habits keep coming back even when we want to change?", "为什么明想改变，坏习惯仍反复出现？")),
               q(("What role does curiosity play in breaking a habit?", "好奇心在戒除习惯中起什么作用？")),
               q(("Describe one habit you would like to understand better.", "描述一个你想更了解的自身习惯。"))],
    "confidence": [q(("Where does real confidence come from?", "真正的自信来自哪里？")),
                   q(("Can confidence be built through practice?", "自信能通过练习建立吗？")),
                   q(("Tell a story about a time you trusted yourself.", "讲一次你相信自己的经历。"))],
    "meaning": [q(("What makes a life feel meaningful to you?", "对你来说，什么样的人生才算有意义？")),
                q(("Is meaning found or created?", "意义是被发现的，还是被创造的？")),
                q(("Who in your life gives you a sense of belonging?", "生命中的谁给了你归属感？"))],
    "mind": [q(("What happens in the brain when we worry too much?", "过度思虑时大脑发生了什么？")),
             q(("How can you take back control of your attention?", "你会如何夺回注意力的控制权？")),
             q(("What helps you calm down when thoughts race?", "念头纷乱时，什么能让你平静？"))],
    "action": [q(("Why do we talk ourselves out of good ideas?", "我们为什么会劝退自己的好想法？")),
               q(("What is the five second rule?", "「五秒法则」是什么？")),
               q(("What is one idea you should act on within five seconds?", "有哪个想法你该在五秒内行动？"))],
    "generic": [q(("What is the main message of this talk?", "这篇演讲的核心观点是什么？")),
                q(("Which sentence impressed you the most?", "哪一句给你的印象最深？")),
                q(("How would you explain this idea to a friend?", "你会怎样向朋友解释这个观点？"))],
}

CATALOG = [
    meta(1, "meg_jay_why_30", "Why 30 Is Not the New 20", "二十岁光阴不再来",
         "二十几岁的人生", "Meg Jay", "进阶", 3,
         ["成长", "人生规划", "心理学"], ["#5B7CF5", "#8B62E8"],
         QUESTIONS["meg_jay"], MEG_JAY, SOURCES["meg_jay"]),
    meta(2, "ted_mind_control", "Take Back Control of Your Mind", "夺回大脑的控制权",
         "专注与内耗", "TED", "进阶", 3,
         ["心理", "专注力", "情绪"], ["#3E7BF0", "#5FC4C8"],
         QUESTIONS["mind"], None),
    meta(3, "levitin_stay_calm", "How to Stay Calm Under Stress", "压力之下如何保持冷静",
         "压力管理", "Daniel Levitin", "进阶", 3,
         ["压力", "决策", "神经科学"], ["#4C6AE8", "#7E8FF5"],
         QUESTIONS["levitin"], LEVITIN, SOURCES["levitin"]),
    meta(4, "ted_true_confidence", "What Is Real Confidence", "什么是真正的自信",
         "自信与自我", "TED", "入门", 2,
         ["自信", "成长", "心态"], ["#E8834A", "#F0B45B"],
         QUESTIONS["confidence"], None),
    meta(5, "ted_why_meaning", "Why We Need Meaning", "我们为何需要意义",
         "人生意义", "TED", "进阶", 3,
         ["意义", "心理学", "幸福"], ["#7D5BE8", "#B07CE8"],
         QUESTIONS["meaning"], None),
    meta(6, "ted_humility_water", "The Way of Water and Humility", "保持谦逊：水之道",
         "谦逊与处世", "TED", "入门", 2,
         ["谦逊", "哲学", "处世"], ["#2F8FA8", "#5FC4B0"],
         QUESTIONS["generic"], None),
    meta(7, "brewer_break_habit", "A Simple Way to Break a Bad Habit", "改掉坏习惯的简单方法",
         "习惯与改变", "Judson Brewer", "进阶", 3,
         ["习惯", "正念", "行为改变"], ["#E06A55", "#F0A05B"],
         QUESTIONS["habits"], BREWER, SOURCES.get("brewer", "TED 官方公开逐字稿")),
    meta(8, "ted_not_personal", "How to Not Take Things Personally", "如何不把事往心里去",
         "情绪边界", "TED", "入门", 2,
         ["情绪", "人际关系", "心态"], ["#4A90D9", "#7EC8E3"],
         QUESTIONS["generic"], None),
    meta(9, "ted_believe_yourself", "How to Believe in Yourself", "如何相信自己",
         "自信与自我", "TED", "入门", 1,
         ["自信", "自我认同", "成长"], ["#F09A4A", "#F2C879"],
         QUESTIONS["confidence"], None),
    meta(10, "ted_meaning_of_life", "The Meaning of Life", "我们活着的意义",
         "人生意义", "TED", "进阶", 3,
         ["意义", "哲学", "幸福"], ["#6A5BE8", "#9B7CE8"],
         QUESTIONS["meaning"], None),
    meta(11, "robbins_five_seconds", "How to Stop Screwing Yourself Over", "五秒之内做出行动",
         "行动力", "Mel Robbins", "进阶", 3,
         ["行动力", "拖延", "自我管理"], ["#E4577A", "#F08A6A"],
         QUESTIONS["action"], ROBBINS, SOURCES.get("robbins", "TED 官方公开逐字稿")),
    meta(12, "esfahani_more_than_happy", "There's More to Life Than Being Happy", "生活不只是快乐",
         "人生意义", "Emily Esfahani Smith", "进阶", 3,
         ["意义", "幸福", "心理学"], ["#5E7CF7", "#9B6CF7"],
         # ted_12.mp4 是 B站分离的 HEVC 视频流，无音轨；等用户补带声音的文件
         QUESTIONS["esfahani"], ESFAHANI, SOURCES["esfahani_smith"],
         audio_override=""),
    meta(13, "ted_self_criticism", "Why Self-Criticism Never Lasts", "靠批判自己无法长久改变",
         "自我接纳", "TED", "入门", 2,
         ["自我接纳", "改变", "心态"], ["#4C8C7A", "#8FC7A8"],
         QUESTIONS["generic"], None),
]


def word_count(s):
    return max(1, len(re.findall(r"[A-Za-z']+", s)))


def distribute(sentences, duration):
    """按词数加权把句子铺满音频时长，句间留小间隙。"""
    weights = [word_count(en) for en, _ in sentences]
    total = float(sum(weights))
    gap = 0.18
    usable = max(1.0, duration - gap * len(sentences))
    out = []
    cursor = 0.0
    for (en, zh), w in zip(sentences, weights):
        span = usable * w / total
        out.append({
            "text": en,
            "translation": zh,
            "startTime": round(cursor, 2),
            "endTime": round(cursor + span, 2),
        })
        cursor += span + gap
    return out


def main():
    os.makedirs(CONTENT, exist_ok=True)
    entries = []

    # 1) 原有 Matt Cutts：保留精确时间戳与手写 clips，只补元数据
    mc_path = os.path.join(CONTENT, "matt_cutts_30_days.json")
    with open(mc_path, encoding="utf-8") as f:
        mc = json.load(f)
    mc.update({
        "titleZh": "用 30 天尝试一件新鲜事",
        "topicZh": "习惯养成",
        "difficulty": 1,
        "tags": ["习惯", "自我提升", "行动力"],
        "coverColors": ["#5E7CF7", "#8E6CF7"],
        "source": "内置 · 精确对齐",
        "transcriptScope": "full",
        "timingSource": "aligned",
        "topicQuestions": [
            q(("What new habit would you like to try for 30 days?", "你想用 30 天尝试什么新习惯？")),
            q(("Why is 30 days the right amount of time?", "为什么 30 天是合适的时长？")),
            q(("What did the speaker learn about small sustainable changes?", "讲者对微小而可持续的改变有什么体会？")),
        ],
    })
    with open(mc_path, "w", encoding="utf-8") as f:
        json.dump(mc, f, ensure_ascii=False, indent=2)
    entries.append({"id": mc["id"], "file": "matt_cutts_30_days.json",
                    "title": mc["title"], "topicZh": mc["topicZh"], "enabled": True})

    # 2) 13 篇素材
    for c in CATALOG:
        data = {
            "id": c["sid"],
            "title": c["title"],
            "titleZh": c["titleZh"],
            "topicZh": c["topicZh"],
            "speaker": c["speaker"],
            "level": c["level"],
            "difficulty": c["difficulty"],
            "durationMs": c["durationMs"],
            "coverUrl": "",
            "audioPath": c["audioPath"],
            "audioMissing": c.get("audioMissing", False),
            "sourceMedia": c["sourceMedia"],
            "tags": c["tags"],
            "coverColors": c["coverColors"],
            "topicQuestions": c["topicQuestions"],
            "source": c["source"],
            "transcriptScope": "excerpt" if c["sentences"] else "pending",
            "timingSource": "estimated" if c["sentences"] else "none",
            "hasTranscript": bool(c["sentences"]),
            "sentences": distribute(c["sentences"], c["durationMs"] / 1000.0)
            if c["sentences"] else [],
        }
        path = os.path.join(CONTENT, c["sid"] + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        entries.append({"id": c["sid"], "file": c["sid"] + ".json",
                        "title": c["title"], "topicZh": c["topicZh"], "enabled": True})

    with open(os.path.join(CONTENT, "index.json"), "w", encoding="utf-8") as f:
        json.dump({
            "version": 2,
            "source": "TED音频素材库 + TED 官方公开逐字稿",
            "entries": entries,
        }, f, ensure_ascii=False, indent=2)

    with_transcript = sum(1 for c in CATALOG if c["sentences"]) + 1
    print("内容源生成完毕：共 %d 篇；含文稿 %d 篇；仅音频 %d 篇"
          % (len(entries), with_transcript, len(entries) - with_transcript))


if __name__ == "__main__":
    main()
