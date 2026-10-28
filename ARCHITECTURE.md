# Camera18 技术架构

当前方案（2026-10-27）：经典相机色彩／影调模拟 + 真实光圈控制。用户仍只控制相机、光圈、后置焦段。

下一轮成像升级的设计见[统一相机模拟技术方案](docs/camera-simulation-plan.md)：以拍摄顺畅、实时风格可感知、成片美感为目标，沿用采集／渲染／存储三个职责。该方案尚未实施，不代表下文现有渲染器已具备新增能力。

## 2026-10-28 拍摄状态与照片交付闭环（最新）

本节对应用户批准执行的产品问题修复，优先于历史挂起清单；不改变三张试拍政策，也不取消相机推荐真实光圈联动。

- 原生采集状态统一表达不可用、曝光中、光学调整中、光圈未到位、处理繁忙、可拍。屏幕和硬件快门走相同 JS 权限/试拍入口，原生再次校验；快门配方随请求冻结。
- 光圈完成回调和3秒兜底均检查硬件回读，超时不自动算成功；失败阻止拍摄并提供重试。拖动请求在 sessionQueue 合并，被取代的请求也正常结束；旧回调不能覆写新光圈状态。
- 焦段 input + zoom 在统一禁拍窗内执行，失败恢复原镜头/变焦/原有真实光圈；恢复失败进入不可用态并提供重建入口。旧事务不能回滚新事务。
- 失败照片保留任务/源，不再被误报为已交付或释放仍在恢复中的试拍名额。照片状态入口提供一次性重试、系统设置、可解码原图导出及明确确认后的本地原图清理；直接底片的失败任务可保留原图并结束等待，代理任务必须继续最终化。
- 有限后台任务用于争取保存时间，到期暂停并保留日志；不承诺杀进程后继续执行。失败任务不占8个活动任务名额，但仍占磁盘，原图存储由用户显式管理。
- 完整分辨率最新照片保留在 Application Support/Camera18Latest，重开可放大查看，缩略图只用于入口。恢复旧照片不会倒退最新照片记录。
- Keychain 按 captureID 持久化预留/提交状态。完成结果先写 Camera18Outcomes，再清理任务、发事件；JS 结算成功后 ACK，未ACK结果在恢复时重放。重复回调幂等，未知ID不消费其他名额；启动只释放上一进程中无任务/结果的孤立预留。

验证分层：JS/离线回归和 prepackage 是静态门槛；Swift 类型、Photos权限/事务、后台到期、硬件光圈与UI交互仍待 CI / 对应设备工程验收。不能据此宣称已通过真机或画质验收。

## 运行架构

| 层 | 职责 | 实现 |
|---|---|---|
| UI／配置 | 选择相机、状态、配方验证与 override | Expo / React Native / TypeScript |
| 采集 | 苹果多摄路由、AF/AE/AWB、主动真实光圈、快门 | CameraEngineModule.swift / AVFoundation |
| 输入适配 | 技术输入差异，独立于相机风格 | CameraInputNormalizer；未实测时 identity |
| 相机响应 | 统一颜色／影调／可选质感 | CameraProfileRenderer.swift + JSON/LUT |
| 输出 | MTKView预览；最终底片获取、持久任务、同资产风格编辑 | CameraPhotoStore.swift；共享CIContext |

不新增按品牌分支、不加用户手动曝光／滤镜强度、不做软件虚化或在线 AI。

## 采集不变量

- `.photo` + `.quality`，默认苹果多摄自动选择；推荐光圈或主动真实光圈控制时约束主摄，焦段表示构图意图。
- 支持时24MP延迟交付，否则直接高质量12MP；HEIF优先，不为像素数量默认选48MP。
- 支持的ZSL/Responsive开启，Fast Capture Prioritization关闭；统一资源预热。
- 切相机自动应用推荐真实光圈（按能力与硬件范围夹取），用户仍可手动调整；AF/AE/AWB自动，曝光和光圈以成片EXIF为准。
- 曝光结束即释放快门，代理只能入库，最终底片才可渲染。PhotoKit非破坏性编辑保持一个相册资产。
- 源/代理、配方、资产ID与错误持久化；恢复幂等；结果按captureID配对。
- 无读取权限：直接质量底片→同源风格→单图入库，原始底片/配方保留本地。

具体生命周期、边界和工程验收见 [高画质采集架构](docs/高画质采集架构.md)。

## 唯一渲染实现

应用与 macOS 离线工具编译相同的 `modules/camera-engine/ios/CameraProfileRenderer.swift`，不复制滤镜逻辑。

共享：输入归一化（当前 identity）→ LUT 强度／色温／饱和／七分区 HSL／分离染色预编译 cube → 曝光 → 对比 → 黑位 → 五点曲线 → deharsh → 暗角。

可选颗粒仅成片执行；八种内置模式当前全部零额外颗粒。预览头部按 1280px 上限降采样，成片全分辨率。ORIG 按 passthrough 原始 bytes 保存，完全绕过渲染与重编码。

工作空间显式 extended linear sRGB；cube 继续指定 sRGB，输出 sRGB。颜色约定 `camera18-srgb-ci-v1`；rendererVersion=4。原生传递函数与像素自检尚待 macOS 执行，不能把 CPU 近似当作原生正确性证明。

每个 Profile + 渲染内容版本 + normalizer + rendererVersion 编译缓存；颜色／tone／texture 改动才失效，同 id 淘汰旧版本，不随光圈拖动重复编译。复用静态 CIContext。

## 配方与证据

`assets/camera-profiles.json` 是八种正式模式唯一配置来源。`recipe` 标记版本／证据状态／颜色约定；开发面板展示 active source 和像素参数指纹，旧 override 保留且可导出备份。raw、曝光偏置、halation/starburst 仅兼容旧导入，不在新配方中冒充有效参数。

离线校准：记录配对数据 → 按完整场景分训练／验收 → 正则化拟合单 LUT 候选 → 同源原生渲染 → 独立验收 → 人工发布。没有真实数据就保持 approximation，不虚构设备补偿。

完整命令、数据结构、发布标准见 [相机校准流程](docs/相机校准流程.md)。`tools/look-tuner.html` 只作配方编辑和已渲染图片比较，无第二套颜色实现。

## 验证

`npm run verify`、`npm run prepackage`；新增离线校准回归已接入 prepackage。native-calibration self-test / render / probes 仅 macOS。Swift 与真机画质、HEIF、帧率、连续拍照仍须单独验收。构建只由用户明确要求后手动触发。
