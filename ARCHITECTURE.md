# Camera18 技术架构

当前方案（2026-10-27）：经典相机色彩／影调模拟 + 真实光圈控制。用户仍只控制相机、光圈、后置焦段。

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

- `.photo` + `.quality`，默认苹果多摄自动选择；主动真实光圈控制才约束主摄，焦段表示构图意图。
- 支持时24MP延迟交付，否则直接高质量12MP；HEIF优先，不为像素数量默认选48MP。
- 支持的ZSL/Responsive开启，Fast Capture Prioritization关闭；统一资源预热。
- 风格推荐光圈不自动执行；AF/AE/AWB自动，曝光和光圈以成片EXIF为准。
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
