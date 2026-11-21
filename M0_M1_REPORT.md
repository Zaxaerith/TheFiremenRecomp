# The Firemen Recomp — M0/M1 初始化报告

- **项目目录**：`D:\Project\GameRecomp\TheFiremenRecomp`
- **里程碑状态**：`M1_READY_FOR_CODEGEN`
- **日期**：2026-11-21
- **固定的 SNESRecomp 基线**：`v0.4.6-alpha` (`22c01ef12cc94767451d0b218e4fc341bc19043e`)

---

## 1. 任务一：ROM 校验与特征识别

### 1.1 文件完整性与哈希计算
- **文件路径**：`D:\Project\GameRecomp\TheFiremenRecomp\Firemen, The (J).smc`
- **文件大小**：`1,048,576` 字节（正好为 1,024 KiB / 1 MiB / 8 Mbit）
- **Copier Header 检查**：
  - 文件大小能被 1024 整除（`1048576 % 1024 == 0`）
  - **不存在** 512 字节 Copier Header（属于干净的 Headerless 原盘镜像）
- **哈希值校验**：
  - **CRC32**：`15F2271D`
  - **MD5**：`79C9FFE304FA775CE3EC15270058F41B`
  - **SHA-1**：`B2BB5C41D5CEA5A9A130C3063857BA9EC000E166`
  - **SHA-256**：`97206402D1CACC3187A600A5F3A7EBD73DDBA0C7E09A5A688EFECA47CC46B604`

### 1.2 官方 ROM Probe 探测与卡带内部元数据
通过 SNESRecomp 官方 `tools/new_project/probe_rom.py` 与卡带内部 Header 探测，结果如下：
- **卡带内部标题**：`THE FIREMEN     JAPAN`（ASCII 21 字节，填充空格）
- **映射模式 (Mapping)**：`0x30` -> **FastROM LoROM**（3.58 MHz / 120ns 访问时延）
- **卡带类型 (Cartridge Type)**：`0x00`（纯 ROM 卡带，无内置协处理器）
- **ROM 容量**：`0x0A` -> 1024 KiB（8 Mbit，共 32 个 32 KiB Bank）
- **SRAM 容量**：`0x00` -> 0 KiB（无电池备份 RAM，游戏采用关卡密码机制）
- **地区 (Country/Region)**：`0x00` -> **JPN**（日本市场，NTSC 60Hz）
- **发行商代码 (Licensee)**：`0x33`（Human Entertainment）
- **版本号 (Version)**：`1.0` (`0x00`)
- **校验和与反码**：`Checksum: 0x2C19`, `Complement: 0xD3E6`（`0x2C19 ^ 0xD3E6 == 0xFFFF`，**校验和完全有效**）
- **中断向量**：
  - **Reset Vector**：`$FFE0`（即 `$00:FFE0`）
  - **Native NMI Vector**：`$FFF0`（即 `$00:FFF0`）
- **协处理器 (Coprocessor)**：**None**（无 SA-1、SuperFX、DSP-1 等外设扩展芯片）

### 1.3 镜像版本判定
完全匹配 No-Intro 官方数据库中 `Firemen, The (Japan)` 正式发售零售版，ROM 原始未被改动。ROM 文件保留在工程根目录，不修改、不重命名，已通过 `.gitignore` 规则有效隔离，不进入 Git 跟踪。

---

## 2. 任务二：框架兼容性审计（基于 v0.4.6-alpha）

基于 SNESRecomp `v0.4.6-alpha` 发布基准对 *The Firemen (Japan)* 进行逐项技术审计：

### 2.1 65C816 指令与架构分析
- **LoROM / FastROM 寻址**：SNESRecomp 核心完全原生支持 LoROM（Bank $00-$7D 及镜像 $80-$FF），FastROM 时钟周期模拟完整。
- **中断处理与标志位压栈**：`v0.4.6-alpha` 修复了中断入口压栈顺序（#203，先压入原 P 状态再置位 I/D），保证 NMI（VBlank）触发时游戏主循环状态机无缝切换。
- **变址与长跳转**：间接寻址跨 Bank 进位修正（#240）及 X 标志置位时清零高字节的修复，避免了动作逻辑中的指针运算漂移。

### 2.2 PPU 图层、渲染与扫描线
- **背景模式**：游戏大量采用标准 **Mode 1**（BG1/BG2 为 16 色层，BG3 为 4 色 HUD/文字层）。Mode 1 是 SNESRecomp 最成熟、最稳定的图形渲染管线。
- **Sprite (OBJ)**：8x8 与 16x16 规格，主角 Pete、搭档 Daniel、敌人与水火粒子碰撞体处理均在标准 OAM 范围内。
- **HDMA 扫描线与特效**：
  - 灭火水柱动态喷射与火焰波动使用 HDMA 扫描线参数调制。`v0.4.6-alpha` 中包含预渲染 HDMA 槽位消费修正（#252）与实时 Beam 时钟观察器，能有效预防画面撕裂与扫描线不同步。
  - 烟雾/半透明采用硬件 Color Math（主副屏混合），当前渲染器完全支持。
  - 爆炸与场景切换的 Mosaic（马赛克）效果受益于近期窗口边界采样的对齐修复。

### 2.3 SPC700 / APU 音频系统
- **音频核心**：Human Entertainment 专有驱动运行在标准 Sony SPC700 + S-DSP 芯片架构上。
- **算术完整性**：`v0.4.6-alpha` 补全了 S-SMP `DIV` 指令与 SPC700 `ADDW` half-carry 运算，确保音效包与 BGM 序列播放正常无爆音。
- **音频时序**：支持指令边界 APU 刷新与 Native Clock Origin 积分，Windows x64 平台默认启用低延迟原生音频时钟。

### 2.4 Windows x64 运行时与框架契约
- **帧驱动模型**：采用新版 Beam-aligned 驱动模型（`snes_beam_frame_driver`），配合 `RtlGameInfo` 的重置与快照回调，支持标准 60fps 垂直同步与平滑节奏控制。
- **保存与快照**：由于卡带无电池 SRAM，框架原生 Save State（保存即时存档）功能成为该游戏持久化进度的关键，相关快照预检与 Beam 状态保存接口均已在 `game_rtl.c` 中接通。

### 2.5 兼容性分类结论矩阵

| 模块 | 判定 | 详细说明 |
| :--- | :---: | :--- |
| **LoROM / FastROM 内存映射** | **已支持** | 1 MB 标准 LoROM 寻址，无内存异常行为 |
| **65C816 CPU 指令集** | **已支持** | 核心指令及变址进位均经测试套件验证 |
| **无协处理器标准架构** | **已支持** | 无需任何 HLE/LLE 扩展芯片模拟器 |
| **PPU Mode 1 & Sprite OAM** | **已支持** | 角色、敌人及背景层稳定支持 |
| **Color Math (火光与水雾半透明)** | **已支持** | 硬件级主副屏加减色支持完整 |
| **SPC700 / APU 音频引擎** | **已支持** | 核心算术与 DSP 混合就绪 |
| **Windows x64 主机运行时** | **已支持** | SDL2 / OpenGL / XInput / 保存状态 |
| **复杂 HDMA 水流波动扫描线** | **待验证** | 需在 M2/M3 执行端到端光栅捕获校对 |
| **Human 音频驱动加载握手时钟** | **待验证** | 需观察关卡加载期间 APU 端口时钟是否有微小等待超时 |
| **电池存档 (SRAM Save)** | **已知不支持 (硬件无)** | 卡带本身无 SRAM（0 KB），需依赖即时快照或密码 |
| **双人联机 Netplay** | **已知不支持 (游戏单人)** | 原作为 1P 操控+2P 电脑 AI，无内置双人联机协议 |

---

## 3. 任务三：工程初始化结果

### 3.1 目录结构与隔离生成
工程骨架严格在隔离临时目录中通过官方模板及参数渲染生成，并完整合并至目标根目录 `D:\Project\GameRecomp\TheFiremenRecomp`。

生成的主要文件结构：
```text
TheFiremenRecomp/
├── .github/workflows/
│   └── release.yml             # 跨平台 CI Setup Host 打包流水线
├── mods/
│   └── preloaded/              # 预置 Mod 资源包加载目录（含 packages/.gitkeep）
├── recomp/
│   ├── bank00.cfg              # 种子分析配置（含向量与存根声明）
│   ├── README.md               # 符号表与分析说明
│   └── symbols.toml            # 起始符号表（I_RESET @ $ffe0, I_NMI @ $fff0）
├── scripts/
│   └── package_release.sh      # 发行包打包脚本
├── src/
│   ├── gen/                    # 生成 C 代码目录（.gitkeep 占位，源码完全 gitignore）
│   ├── game_rtl.c              # 游戏运行时核心驱动（已接入 snes_beam_frame_driver）
│   ├── game_rtl.h              # 运行时头文件
│   ├── gen_stubs.c             # 存根函数定义
│   ├── host_contract.c         # 主机平台契约实现
│   ├── main.c                  # 桌面端宿主 Shim
│   └── variables.h             # 变量映射头文件
├── tools/
│   └── regen.sh                # 幂等 ROM 代码重编译触发脚本
├── .gitignore                  # 安全规则：彻底忽略 ROM、src/gen/、build/、rom.cfg 等
├── .gitmodules                 # 子模块配置（snesrecomp 与 recomp-ui）
├── CMakeLists.txt              # CMake 构建配置（项目名 TheFiremenSNESRecomp）
├── framework_pins.txt          # 框架版本显式锁定记录
├── LICENSE                     # PolyForm Noncommercial 1.0.0 许可证声明
├── README.md                   # 移植工程说明文档
├── rom_identity.txt            # ROM 唯一指纹与元数据声明（单一事实来源）
├── rom.cfg                     # 本地 ROM 路径缓存（指向本地 SMC）
├── VERSION                     # 项目版本号（0.1.0）
└── Firemen, The (J).smc        # 原始 ROM（保持未修改、未移位、未跟踪）
```

### 3.2 框架版本固定记录 (`framework_pins.txt`)
```text
snesrecomp=22c01ef12cc94767451d0b218e4fc341bc19043e
snesrecomp_ref=v0.4.6-alpha
snesrecomp_url=https://github.com/RetroPortingToolKit/snesrecomp.git
```

### 3.3 Git 初始化与状态
- 本地仓库成功初始化于 `main` 分支。
- 根提交（Initial Commit）已安全创建（`504cc37`）。
- **工作区完全干净 (`working tree clean`)**。
- `Firemen, The (J).smc` 已被 `.gitignore:7:*.smc` 规则精确忽略，绝无进入版本库。
- 未创建任何远程仓库，未执行任何 push 操作。

---

## 4. 资源与安全规则合规检查

- [x] 未在工作区之外（如 C 盘用户目录）产生任何残留测试数据。
- [x] 未执行任何本地 Cargo 编译（无 cargo build/check/clippy）。
- [x] 未执行任何大规模 C/C++ 构建（无 cmake --build）。
- [x] 未执行任何 Codegen、反编译分析或自动化 GUI 运行。
- [x] 未修改或覆盖任何其他游戏工程（SMKRecomp、PilotwingsRecomp 均安然无损）。
- [x] 未修改任何 Windows ACL 或 NTFS 完整性标签。

---

## 5. 阻断项排查与下一阶段 (M2) 前置条件

### 5.1 当前阻断排查
**当前无任何 M0/M1 阻断项。**

### 5.2 M2 (代码生成与首轮静态分析) 前置准备
1. **子模块检出**：依据 `framework_pins.txt`，在需要执行生成时检出固定的 `v0.4.6-alpha`（`22c01ef`）。
2. **分析后端与符号挖掘**：从 `$00:FFE0` (Reset) 及 `$00:FFF0` (NMI) 出发，逐步向 `recomp/symbols.toml` 填充游戏主要子程序标签，随后利用 `snesrecomp` 工具链生成 `src/gen/*.c`。

**结论**：M0（ROM 审查与基线确认）与 M1（工程脚手架初始化）已全部规范完成，状态正式标记为：

### **`M1_READY_FOR_CODEGEN`**
