# JiJiDownMac

**唧唧（JiJiDown）2 的 macOS 原生客户端 —— 非官方，第三方实现。**

> ⚠️ **本项目与唧唧官方无任何隶属关系，未获其背书。**
> 「唧唧 / JiJiDown」及其核心二进制的版权归**唧唧作者**所有。本仓库不包含、
> 不分发其二进制，构建时从官方地址获取。详见 [NOTICE.md](NOTICE.md)。

---

## 这是什么

唧唧 2 的官方形态是「**核心二进制 + WebUI**」。但官方 WebUI 地址并不公开 ——
文档写明需要加入体验群才能拿到。也就是说，走官方路径你下载到的只是一个**没有
界面的守护进程**。

这个项目补上那个缺失的界面：一个自包含的 macOS App，**自己托管核心进程**
（下载、校验、写配置、启停、崩溃重启、日志捕获），用 SwiftUI 提供完整 UI。
双击即用，全程不碰终端。

### 为什么不算「重新实现」

官方核心在 `external-controller` 上暴露**原生 gRPC** 接口，其文档明确把
Swift 列为受支持语言，`.proto` 里还带着 `option csharp_namespace` ——
厂商本就在做多语言 SDK。**第三方写原生客户端是其设计之内的事**，不需要逆向。

所有下载能力、账号授权、会员限制**都由官方核心提供**，本项目不做任何绕过：
核心说不行就是不行，客户端只负责把话说清楚。

## 功能

| 模块 | 能做什么 |
|---|---|
| **账号** | 扫码登录（二维码内嵌在窗口里，带倒计时与刷新）、Cookie 导入（可另带 AccessToken，**未验证**）、账号信息与授权头衔（`badge`） |
| **解析** | 粘贴链接或 BV 号 → 标题 / 封面 / UP主 / 分P，分P 多选（全选 / 反选 / 清空） |
| **下载** | 清晰度（8K / **杜比视界** / HDR / 4K / 1080P60 / … / 360P）、编码（AVC / HEVC / AV1）、音质（**杜比全景声** / 192K / 132K / 64K）、**仅下载音频**（产物 mp3）—— 档位只是**可选**，能不能下取决于视频本身与核心（HDR / 全景声尤其）；Hi-Res 归在「核心没做」那栏，见「已知限制」 |
| **批量** | 多选分P 一次性提交 —— **逐条 `Task.New`**，不是 `Task.NewBatch`（那个被授权门挡死，见「已知限制」） |
| **接口** | WEB / TV / APP 三选一，默认 WEB。**目前只有 WEB 下得了**，选了 TV / APP 界面会当场警示 |
| **任务** | 队列与进度、速度与 ETA、暂停 / 继续 / 删除、在访达中显示产物 |
| **核心** | 运行状态、实时日志、崩溃自动重启、**检查更新（只提示，不下载不安装）** |

**杜比视界（清晰度 id `126`）需要配合 HEVC 编码**，界面上有提示。

## 构建

需要 macOS 15+ 与 Swift 6.1+。**不需要 Xcode** —— 只需 Command Line Tools，
`.app` 由脚本手工组装（本机没有 `xcodebuild`/`actool`，图标走不了 Asset Catalog）。

```bash
brew install protobuf          # 代码生成要 protoc

./Scripts/fetch-core.sh        # 从唧唧官方地址拉核心二进制并校验 sha256

swift build --build-system native   # 首次会拉 ~20 个 SwiftNIO 系依赖，比较久
./Scripts/bundle.sh            # 组装 dist/JiJiDown.app

open dist/JiJiDown.app
```

**在本机的 Command Line Tools 环境下要带上 `--build-system native`。**
不带时 SwiftPM 会走它的默认构建引擎，在只有 CLT、没有完整 Xcode 的机器上会
全量重编整个依赖树并因工作目录问题失败 —— **那是构建引擎的事，与代码无关**，
换回上面这条命令就能过。

网络受限时给 SwiftPM 带上代理：

```bash
HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 \
    swift build --build-system native
```

### 开发工具

`JiJiProbe` 是协议层探针（不进 App bundle），用来在没有 UI 的情况下验证核心行为：

```bash
swift build --build-system native
.build/debug/JiJiProbe                              # 连通性与授权门探针
.build/debug/JiJiProbe status                       # 登录状态
.build/debug/JiJiProbe dl BV1xxxxxxxxx "" 126 hevc  # 下载（126=杜比视界）
.build/debug/JiJiProbe dl BV1xxxxxxxxx              # 默认 1080P / HEVC
```

清晰度与编码按位置给：`dl <BV号> [文件名] [清晰度id] [编码]`，第 2 个位置参数
就是 `TaskNewReq.save_filename`（核心命名模板的主干名，**实测生效**，
见下方「已知限制」）。

其余子命令是这一轮实测用的探针：`trace`（高频读一条任务的**原始状态值**）、
`batch`（复验 `Task.NewBatch` 那道门，以及 `Task.List` 的顺序稳不稳）、
`cid`（列分P 的 cid）、`api`（复验 TV / APP 走到哪一步失败）、`checkupdate`。

## 已知限制

分两类：**核心还没做完的**，和**核心行为本身的坑**。对照依据是官方路线图
<https://client.sabe.cc/quick_start/road_map_2/> 与官方 Python 客户端
[JiJiDown/jithon](https://github.com/JiJiDown/jithon) 的实现。

下面一律分清三种情况，不写成笼统的「不支持」：

- **核心没做** —— 接口压根不存在，或对谁都报 `function not allowed`（如番剧）。
- **被授权挡着** —— 接口在，核心也用 `function not allowed` / `It's a premium
  feature` 拒绝，但拒绝的理由是它的授权位没放行（如 `Task.NewBatch`，
  实测 `failedPrecondition: DownloadBatch function not allowed`）。
  TV / APP **不属于这一栏**：核心在建任务那一步照收，失败发生在之后的取播放
  地址（现象已定、原因未定，见下面第二类里那条）。
- **客户端没接** —— 核心那边能做，本项目还没做。已知两处：一是**下载目录**
  （`config.yaml` 的 `download-dir`）**只能读不能改** —— 客户端会读它、产物定位
  就靠它（`CoreManager.downloadDirectoryFromConfig`），但界面上是只读展示
  （`CoreLogView` 的 `DownloadDirectoryRow`）；改它要写配置 + 重启核心，那条路
  有代码没入口（`CoreManager.rewriteConfig`）。本轮不加是因为改配置只能靠重启
  核心生效，会把正在进行的下载全部掐断，得先解决这个再给入口。二是
  `Task.Notification` 这条推送流（客户端改用每 2 秒轮询 `Task.List`），
  它实际能不能用没验过。

### 一、核心还没做，或做了但被授权挡着

这些**不是本客户端的缺口** —— 接口要么不存在，要么在核心那侧就被拒绝：

| 功能 | 性质 | 核心的实际回应 |
|---|---|---|
| 番剧 / 课程 | 核心没做 | `GetBangumiList function not allowed` —— 这个函数名不在授权门名单里，登录也解不开 |
| up主投稿列表 | 被授权挡着 | `GetUPSubmitVideoList It's a premium feature` |
| 合集 / 列表 | 被授权挡着 | `GetUpSpaceSeriesAndCollectionList It's a premium feature` |
| 个人收藏夹 | 被授权挡着 | `GetFavoriteList It's a premium feature` |
| 可用清晰度枚举 | 被授权挡着 | `AllQuality It's a premium feature` |
| **批量下载接口** | 被授权挡着 | `failedPrecondition: DownloadBatch function not allowed` —— 客户端改用逐条 `Task.New` 实现批量，见下 |
| 弹幕 | 核心没做 | 公开 proto 里没有对应 RPC —— 从客户端这侧就是「接口不存在」。核心里另有 `DownloadDanmaku` 这条授权位，说明它内部可能有对应实现，但同样在 premium 门后。官方 Python 客户端里 `download_danmaku` 就是个 `pass` |
| 字幕 / 互动视频 / Hi-Res / 订阅 | 核心没做 | 路线图列为施工中 |

**批量下载不是核心的功能，是客户端自己做出来的。** `Task.NewBatch` 被授权门挡死
（上面那一行），所以本客户端的批量是「**多选分P → 逐条 `Task.New`**」：一个分P
一条任务，按界面顺序依次提交。判据是实测 —— 逐条提交能建起任务，走 `NewBatch`
则一律拿到 `DownloadBatch function not allowed`（探针 `JJD_BATCH_SINGLE=1`
就是这个对照组）。代价是这些任务在核心眼里是彼此独立的：核心不给批次 id
（`TaskNewBatchReply` 里只有 `callback` 和 `err`，没有任务 id），
所以「一组一起暂停」这类操作没有基础。

**`save_filename` 不在「核心没做」这一栏里。** 上一版 README 把它列在这里
（「路线图列为施工中」），那是 proto 字段错位造成的误判 —— 它实测是生效的，
只是语义是「主干名」。详见下面第二类里的第一条。

**关于那句 `It's a premium feature`：** 这句**不是 B 站返回的错误**，是核心自己说的 ——
文本里嵌着唧唧自己的内部函数名（`GetUpSpaceSeriesAndCollectionList`、`GetFavoriteList`、
`AllQuality` …），B 站吐不出这种字符串。核对二进制可见，核心有一整套按功能开关的授权
模块 `go/internal/core/license`：

```
AllQuality  APIWEB  APITV  APIAPP  BypassAPIRateLimit
DownloadVideo  DownloadAudio  DownloadBangumi  DownloadBatch  DownloadDanmaku
GetVideoList  GetBangumiList  GetFavoriteList  GetUPSubmitVideoList
GetUpSpaceSeriesAndCollectionList
```

授权由唧唧自己的服务器下发（`jijidown.server.License/Update`，主机 `https://sabe.cc` /
`https://beta.sabe.cc`），回复带签名，两边的字段就这些：

```
LicenseUpdateReq   { os, arch, mid, core_version }
LicenseUpdateReply { payload, signature }
LicensePayload     { timestamp, badge, global, basic, premium }
```

实测启动时取一次，之后约每 30 分钟一次（`manager.log` 里的 `[license] Update License`）。

已经实测到的是两条：

- **登录态解不开这道门。** 本机登录的账号 `VIP=true`、`vip_label_text=年度大会员`，
  上表里报这句的那几项照旧全被拒。所以「登录了、是大会员就能用」不成立 ——
  真正靠登录解锁的是 `GetVideoList` / `DownloadVideo`，那两个报的是
  `function not allowed`，登录后就通了（分类见 `CoreError.from`）。
- **请求里没有任何「购买」字段。** 只有 `os / arch / mid / core_version`，
  没有激活码、订单号一类的东西 —— 客户端这边不存在购买路径。

**没验到的，不猜：** 服务端按什么给 `basic / premium / global`。二进制里只看得见它把
B 站 mid 报了上去，判定规则看不到。厂商自己的 Python 客户端把这几种错误记作
「无唧唧会员权限」，而**官网明确写着唧唧「终身免费提供使用」** —— 两句话摆在一起，
只能说「存在一套按账号下发的授权分级」，至于它收不收费、什么条件才给，本项目没有证据。

`LicensePayload.badge`（头衔）会落到 `UserInfoReply.badge`，账号页已经在显示它
（`AccountView.swift:54`）—— 这是客户端唯一能看见「授权到手了没」的地方。

客户端能做的只有把话说清楚：拿不到枚举就给出完整档位下拉，选错档位时报错让人换一个。

### 二、核心行为的坑（客户端已绕开）

- **`save_filename` 是生效的，只是它的语义是「主干名」。** 上一版 README 说它
  被核心无视，那是 proto 字段错位造成的误判 —— 当时它被发在 8 号字段上，而核心
  读的是 9 号，于是被当成未知字段静默丢弃。对齐之后实测：它填进核心命名模板的
  第一个 `%s`，也就是标题位，产出

      <save_filename> (清晰度角标, 编码, 音质角标, 接口).<扩展名>

  判据：传 `"墨脱-1080P"` 进去，文件名的主干就是它（三条逐字实测写在
  `OutputNaming` 的类型注释里）。客户端现在**用它命名与配对**（见下面「配对」那条）。

  两条边界：

  - **扩展名由核心定**：视频永远 `.mp4`、仅音频永远 `.mp3`。带扩展名进去也不会
    被去掉 —— `标题.mp4` 出来是 `标题.mp4 (…).mp4`，双扩展名。
  - **带 `/` 会让任务直接失败**：实测会让 ffmpeg 报错、任务转 `TASK_ERROR`、
    **不产出文件**。所以提交前必须过一遍 `OutputNaming.sanitized`（把 `/`、`\`、
    `:`、NUL 换成 `_`，去掉会让文件变隐藏的前导点，再按 UTF-8 **字节**截到 150
    —— 文件名 255 字节的上限是按字节算的，一个汉字 3 字节）。

- **核心遇到同名文件是静默覆盖的**：不加 `(2)`、不报错。这是核心的行为，不打算
  靠它兜底。所以「绝不覆盖」只能由客户端保证，而且是**在提交之前**保证 ——
  `OutputNaming.availableStem` 会拿「目录里已有的文件名 + 本次运行已占用的主干」
  一起避让，撞了就加 ` (2)`、` (3)`。等下载完再改名兜底就晚了，那时文件已经被
  盖掉了。

  生成的配置里 `max-task: 1`（串行下载）是这条防线的另一半：并行时会有多个任务的
  产物往同一个目录里落，账面看着不冲突的名字（撞名后缀刚加上、文件还没落盘）也会
  真的撞上。代价是不能并行下载 —— 但比静默丢文件强。

- **任务与标题的配对不能靠列表顺序。** 实测 `Task.List` 的返回顺序**不稳定**：
  同一份列表连读几遍，顺序会翻转。所以老做法（等新任务出现在列表里、按出现顺序
  认领排队中的标题）会配出**错的标题**。

  可靠凭据是 `TaskStatusReply.task_title` —— 核心把它设成我们提交的
  `save_filename` **原样回显**（不传时是空串），拿它反查与列表顺序无关。
  反查不到的**不给标题**（宁可空着，界面退回显示回显名），并在任务页显式标出来，
  不按顺序猜。**但主干名照记**：回显的 `task_title` 本身就是主干名，配不上对只说明
  本地那本标题对照表里没有它（命令行探针/官方客户端建的、App 重启前建的都算），
  跟「产物在哪」无关 —— 不记的话这些任务会被定位整个跳过，产物明明在盘上，
  「在访达中显示」却一直灰着。

- **任务状态停在 5，不会翻到 6。** 实测（r339）成功的序列是 `2 → 3 → 4 → 5`，
  失败是 `2 → 0`、暂停是 `3 → 1`；枚举值 **6（`taskComplete`）从未出现过**。
  所以完成判据是 `completeTime > 0`（`TaskStatusReply.isFinished`），不是看枚举。

  值 5 在枚举里的名字是 `taskGenmusic`（本项目显示成「提取音频」），而实测它在
  普通视频下载里同样落到终态 —— 这个名字**描述不了实际发生的事**，只能当标识用，
  不能当判据。

  仓库现有的 `TaskStatusType` 枚举值与实测**吻合**（0 error / 1 pause / 2 running /
  3 wait / 4 mergeing / 5 genmusic / 6 complete），**不要改**；只有「6 从未出现」
  这一点要记着。核心内嵌的那份定义（0 ALL / 1 ERROR / 2 STOP / 3 WAIT / 4 RUNNING /
  5 COMPLETE）与实测行为对不上，是遗留定义。

  **注意是 `> 0` 不是 `!= 0`** —— 未完成时核心给的是 `-62135596800`，
  即 Go 零值 `time.Time`（公元 1 年）的 Unix 秒数。写成 `!= 0` 的话，
  任务一建出来就被判成已完成。

  同一个 0 在**两个位置**上含义还不一样：当**过滤条件**（`Task.List` 的
  `task_status`）时它是「不过滤」，列的是全部任务；当**任务自己的** `taskStatus`
  时它才是「出错」。所以客户端把「列全部」单独开成 `listAllTasks()`，
  不去写 `.taskError` 那个会读错的名字。

- **核心会重写 `config.yaml`，任何注释都留不住。** 核心在写回登录态时用 Go 的
  `yaml.Marshal` 重新序列化整个配置，注释一条不剩 —— 本机那份的第一行直接是
  `log-level: info`，而 `access-token` / `cookies` 是核心自己填进去的。

  所以「这份配置是本客户端写的吗」**不能用配置文件里的注释当标记**：标记一丢，
  客户端就会永远认定「这是用户手写的，别动」，于是 `max-task: 1` 与下载目录再也
  落不了地（后果是产物可能被静默覆盖、界面还按自己的目录去找文件，静默找不到）。

  现在的做法是一个**旁路标记文件** `~/.config/JiJiDown/.managed-by-client`：
  只有「`config.yaml` 本来不存在」或者「标记文件在」两种情况才写配置，其余一律
  一个字都不动，并在日志里说清楚这次哪两项没落地、以及要让客户端接管该怎么做。
  写配置时会**沿用文件里已有的 `user-info` 那几项**（`access-token` / `cookies` …）
  —— 不抄回去就等于每次启动都把用户登出。

- **TV / APP 接口目前下不了。** 建任务这一步会被**照收**（不在 gRPC 层被拒），
  但 3~4 秒后在「取播放地址」那步失败，核心日志里是
  `[playurl] API TV not allowed` / `API APP not allowed` —— 产出零字节，
  任务随即转「出错」。探针的 `api` 子命令能随时复验这条。

  **核心不把错误文本回给客户端**（`TaskStatusReply` 里没有错误字段），所以界面
  只能按任务的 `api_type` **事后归因**（出错 + 非 WEB 才这么提示），不能替核心
  说出原因。

  两个候选原因，**都没验到底**：

  1. **授权位没放行。** 反汇编看，核心的三个接口入口（WEB / TV / APP）读的是
     同一个位掩码的 **bit5 / bit6 / bit7**，TV / APP 那两位在本机没被点亮。
     这与「`It's a premium feature` 是核心自己的授权模块说的」是同一套机制的另一面。
  2. **缺 `raw-access-token`。** 官方客户端的 Cookie 导入界面写着「AccessToken 值，
     **用于登录 TV、APP 接口**」，而 `User.ImportCookie(cookies, access_token)`
     正好有这两个参数，对应配置里的 `raw-cookies` / `raw-access-token` ——
     实测这两个在本机都是空的。

  为什么两个都只说「最像」，不说「就是」：候选 1 只有静态证据（反汇编），
  没有「点亮这两位之后 TV 就通了」的行为验证；候选 2 要验就得先登出、再导入
  cookies + 一个 TV AccessToken（已登录时核心会拒绝 ImportCookie：
  `User already logged in`），而那个 token 从哪来没查清。

  客户端目前的做法：默认走 WEB（`api_type` 默认 0），并且在**选的当下**就把
  「这条现在下不了」讲清楚（下载页的接口警示、任务行上的事后归因）。「账号」页
  已经做出 AccessToken 输入框（可选），等哪天拿到一个真 token，候选 2 可以当场验。

  官方客户端在这点上给用户的提示是：「WEB接口仅支持WEB接口下载，TV接口支持全接口下载」，
  且 TV 接口能下部分 UP 主的**无水印**内容 —— 所以这条路打通是有价值的，
  只是还没打通。

- **`video_codec = UNKNOWN(0)` 会让核心 panic**（`index out of range [0] with length 0`，
  在 `JDMTask.NewSession`）。协议层已硬性拦截，默认编码是 HEVC。
- **核心自带的 `-stop-with-process <PID>` 是坏的。** 那个参数看上去正是用来
  防止核心变成孤儿的，可惜实测（r339）无效 —— 盯着父进程被 `kill -9`，它纹丝
  不动（隔离验证等满 90 秒）。所以本项目不用它，改成启动前自己收尸：
  `CoreManager.reapStaleCore()` 会找出占用端口、**且可执行文件正是我们安装的
  那份**的残留进程，先 SIGTERM 再 SIGKILL。判据卡两道，不会误伤别的东西。
- **控制器端口零鉴权。** 任何能连上 4000 端口的进程都能读任务列表、导入 Cookie、
  删本地文件。客户端只连 `127.0.0.1`，绝不监听 `0.0.0.0`。
- `125`（HDR）与 `30250`（全景声）是否可用**取决于视频本身**，不是所有视频都有。

## 目录结构

```
Sources/
├── JiJiProtos/     .proto 定义 + grpc-swift 代码生成配置
├── JiJiKit/        协议层（CoreClient）+ 核心托管（CoreManager）+ 清晰度枚举
├── JiJiDown/       SwiftUI 应用
└── JiJiProbe/      协议探针（开发工具）
Scripts/
├── fetch-core.sh   从官方地址取核心二进制并校验
├── bundle.sh       手工组装 .app
└── smoke-core.sh   核心二进制冒烟测试
```

### 公开 proto 与实际线上格式不一致（已按实测修正）

上游公开的 `.proto` 与 r339 核心**对不上**。分两种坏法：一种是照原样编译就
解析失败或读出空值（`bvideo.proto`），另一种更阴 —— 不报错，只是把参数**静默
丢掉**（`task.proto`）。改过的地方都在 `Sources/JiJiProtos/` 里，原因写在文件内注释。

**`bvideo.proto`，四处：**

| 字段 | 上游 proto 说 | 实测实际是 |
|---|---|---|
| `BvideoInfoReply` 字段 3 | `string video_title` | `repeated BvideoBlock`（视频块）|
| `BvideoInfoReply` 字段 2 | `bytes video_cover` | 嵌套消息 `BvideoMeta`，封面只是它的子字段 |
| `BvideoPage` 字段 7 | `repeated string page_info` | 单个 `string`（发布时间）|
| `BvideoPage` 字段 8 | 上游漏了这个字段 | `string`（时长文本，如 `47:44`）|

第二处不修的表现很直观：封面、UP 主、简介全是空的 —— 因为把一整段嵌套消息
当图片字节喂给了 `NSImage`。字段编号是靠抓原始 wire 字节、再用两个视频比对
确认的（`meta` 的 8 号子字段在两个视频里取值相同，所以那是 UP 主 mid，不是播放量）。

后两处（字段 7、8）**都不会报错**，坏法更阴：字段 7 上游说 `repeated string`、
实测是单个 string，两者 wire type 都是 length-delimited，按 repeated 解出来是
「每次都只有一项的数组」—— 语义被悄悄带偏，真按「信息列表」去用就会写错代码；
字段 8 上游整个漏了，核心发过来的时长文本被当未知字段丢掉。字段 7 是这一轮新修的。

**`task.proto`，`TaskNewReq` 的字段 8~11：**

| 字段 | 上游 proto 说 | 实测实际是 |
|---|---|---|
| 8 | `string save_filename` | `SourceType source`（枚举）—— 上游整个漏了 `source`，其后**全部错位一位** |
| 9 | `bool audio_only` | `string save_filename` |
| 10 | `uint64 callback` | `bool audio_only` |
| 11 | （上游没有） | `uint64 callback`（批量下载回调）|

后果两个，都是实测到的：

1. **`save_filename` / `audio_only` 被静默丢弃。** 它们落在核心不认识的位置上，
   wire type 也对不上（proto 说 string / bool，核心在 8 处期待枚举、9 处期待
   string），被核心当未知字段丢掉 —— 传了也没用，还没有任何报错。**上一版
   README 里「核心无视 `save_filename`」「仅音频做不了」两条结论的真实来源就是
   这里**：不是核心没做，是参数发错了字段。对齐之后 `audio_only = true` 确实只下
   音频（本次样本产出 253,067 字节的 mp3、无视频轨，`TaskStatusReply.audio_only`
   回显 true 可作判据）。
2. **`callback` 会被核心当成 `audio_only`。** `callback` 是 uint64、核心在 10 号
   期待 bool，两者 wire type 都是 varint，所以**能解出来** —— callback 一旦非 0，
   这个任务就变成「仅下载音频」。**改代码时别踩回去**：字段号只在
   `CoreClient.makeNewReq` 里出现一次，`Task.New` 与 `Task.NewBatch` 共用它，
   两处不会再各错一遍。

### 两个容易踩的坑（都已处理，改代码时别踩回去）

1. **代码生成插件会静默失败。** `GRPCProtobufGenerator` 靠一个固定文件名的
   `grpc-swift-proto-generator-config.json` 驱动；文件缺失或名字写错，它
   **什么都不做也不报错**。所以 `Sources/JiJiProtos/` 里放了个
   `ProtosTarget.swift` 占位文件 —— 没有它，SwiftPM 不认为这是个有效 target，
   插件根本不会跑。
2. **`google/protobuf/empty.proto` 必须放在 target 目录之外**（见
   `Protos-External/`）。放进去的话插件会连它也生成一份 Swift 代码，与
   `SwiftProtobuf` 模块自带的 `Google_Protobuf_Empty` 重复定义，编译失败。

## 许可证

本项目源码采用 [MIT](LICENSE)。`.proto` 接口定义与 `JiJiDownCore` 二进制
**不受** MIT 覆盖，版权归各自作者 —— 详见 [NOTICE.md](NOTICE.md)。

仅供学习与个人使用。使用者需自行承担遵守 B 站服务条款、著作权法与唧唧用户
协议的责任。
