# AppStoreControl 技术文档

AppStoreControl 注入 `com.apple.AppStore`，直接使用 App Store 进程已有的账号、Cookie 和 entitlement。它的功能分为两部分：

1. 获取某个 App 仍可下载的历史版本列表。
2. 下载用户选中的版本，并替换当前已安装的版本。

第三方接口都是私有 API，通过 `NSClassFromString` 和 `objc_msgSend` 调用，不在编译时链接。

## 涉及的标识

| 名称 | 含义 | 示例 |
|---|---|---|
| `adamId` / `salableAdamId` | App 在商店中的 ID | `333903271` |
| `externalVersionId` / `appExtVrsId` | 某个构建的外部版本 ID，指定版本全靠它 | `891738139` |
| `displayVersion` | 用户看到的版本号，可能重复 | `12.29` |
| `bundleVersion` | 构建的 `CFBundleVersion` | - |
| `pricingParameters` | 请求类型。`STDRDL` 表示重新下载，`STDQ` 是默认值 | `STDRDL` |

## 代码结构

| 文件 | 职责 |
|---|---|
| `Tweak.x` | 入口：长按获取按钮打开版本列表，长按账号按钮打开菜单 |
| `ASTCVersionListViewController` | 版本列表界面、确认弹窗、触发安装 |
| `ASTCStoreClient` | 列表流程编排、磁盘缓存、逐个探测版本 |
| `ASTCStoreServices` | 向 Apple 发请求：取 ID 列表、取单个版本、发起安装 |
| `ASTCPackageInfoReader` | 用 Range 请求读取 IPA 内的 `Info.plist` |
| `ASTCInstaller` | 安装路径的顺序和安装结果校验 |
| `ASTCUtils` | 获取账号所在商店的地区代码 |
| `ASTCLocalization` | 根据系统语言返回界面文案的中文翻译 |

---

# 一、获取历史版本列表

## 总流程

入口是 `-[ASTCStoreClient fetchProductForAdamID:progress:completion:]`：

1. 查询 App 基本信息（名称、bundle ID、图标等）。
2. 检查 App 是否已安装，未安装则到此结束。
3. 先显示上次缓存的版本。
4. 向 Apple 获取全部版本 ID。
5. 用已知信息和缓存补全部分版本。
6. 从新到旧逐个探测其余版本，最多 60 个。
7. 合并结果写入缓存，刷新列表。

## 1. 查询 App 基本信息

```text
GET https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup
    ?version=2&id=<adamId>&p=offer&caller=MDM&platform=itunes&cc=<cc>
```

`cc` 必须是账号所在的商店地区，而不是设备的系统地区，否则可能查不到 App 的信息。

`+[ASTCUtils loadStorefrontCountryCodeWithCompletion:]` 按以下顺序取值，总等待上限 5 秒：

1. `-[SSDevice sdk_loadStorefrontCountryCode:]`
2. `NSLocale` 的地区
3. `us`

`SKStorefront.countryCode` 返回三字母代码，不能直接用作 `cc`，所以没有采用。

## 2. 检查安装状态

`queryInstallStateForBundleID:` 通过 `ASDAppQuery` 向 appstored 查询，同时取得已安装的版本号和 `storeExternalVersionID`。

| 结果 | 处理 |
|---|---|
| 已安装 | 继续 |
| 未安装 | 不发任何购买类请求，提示 `Version history is only available for installed apps.` |
| 查询失败或 6 秒超时 | 提示下拉重试 |

## 3. 建立商店身份

`prepareStoreIdentityWithCompletion:` 从 `SSAccountStore.activeAccount` 取得账号，并准备 token、Cookie、Storefront、商店 Host 和 DSID。

它会先发一次 `SSAuthenticateRequest` 预检（最多等 20 秒）。结果缓存 300 秒，避免每次探测都重复准备。

## 4. 获取版本 ID 列表

入口是 `fetchVersionIdentifiersForAdamID:completion:`。

```text
POST https://<host>/WebObjects/MZBuy.woa/wa/buyProduct?guid=<guid>

productType=C&price=0&salableAdamId=<adamId>&pricingParameters=STDRDL&clientBuyId=1&installed=0
```

请求通过 `SSURLConnectionRequest` 由 itunesstored 发出。它只是普通 HTTP 请求，不使用 `SSPurchase`，也就不会进入购买或下载队列。

从响应中读取：

| 字段 | 用途 |
|---|---|
| `softwareVersionExternalIdentifiers` | 全部版本 ID，从旧到新 |
| `softwareVersionExternalIdentifier` | 最新版本的 ID |
| `bundleShortVersionString` | 最新版本的版本号 |
| `minimumOSVersion` | 最新版本的最低系统要求 |
| `deltaPackages` 内的 `priorVersion*` | 部分近期版本的 ID 与版本号 |

### 回退：跟随 Buy 动作

如果响应没有列表，而是返回了一个带 `okButtonAction` 的 dialog，`ASTCFollowableBuyParameters` 会逐项检查它的动作。全部满足才能跟随：

- `kind` 是 `Buy`。
- 带有 `buyParams`。
- `price` 明确为 0。
- `pricingParameters` 是 `STDRDL`。
- `salableAdamId` 与当前 App 相同。

通过后调用 `nativeCompatibilityBuyForAdamID:externalVersionId:buyParameters:completion:` 跟随一次，并从响应中读取列表。之后保存这组参数，后续版本也走同样的请求。

如果响应要求授权（`failureType` 为 `2071`、`2077`，消息含 `BadPasswordToken`，或 dialog 的 `kind` 为 `authorization`），又不满足跟随条件，就停止查询。

### 为什么原生请求不会触发下载

这是列表查询中最重要的安全约束。`nativeCompatibilityBuyForAdamID:` 使用 `SSPurchaseRequest`，它默认会创建下载任务，所以代码做了以下限制：

| 限制 | 做法 |
|---|---|
| 只接受免费 | 参数中 `price` 不为 0 时，在建立请求前中止 |
| 不创建下载 | `SSPurchase` 的 `createsDownloads`、`createsJobs`、`createsInstallJobs` 全部设为 `NO` |
| 请求层同样禁止 | `SSPurchaseRequest` 的 `createsDownloads`、`createsJobs` 也设为 `NO`。**发送时请求的值会覆盖 purchase 的值，默认是 `YES`，这一步不能省** |
| 标记为重新下载 | `usesLocalRedownloadParametersIfPossible` 设为 `YES`，并设置 `SSDownloadPropertyIsRedownload` |
| 不进入校验流程 | `shouldValidatePurchases` 设为 `NO` |
| 拒绝收费响应 | dialog 的 `okButtonAction` 带非 0 价格时直接中止 |

此外，该请求设置 `needsAuthentication=YES`，并且必须在主线程启动，否则 StoreKitUI 的断言会终止进程。按代码注释，需要授权时系统可能弹出 Apple ID 密码框。超时上限是 90 秒。

## 5. 用已知信息补全

`resolveIdentifiers:product:pricingParameters:cache:progress:completion:` 不发请求就能先填入以下版本：

- 响应中的最新版本。
- 本机已安装的版本。
- `deltaPackages` 列出的近期版本。
- 磁盘缓存中已解析的版本。

这些版本立即显示。但只有同时满足“有 `bundleVersion`”和“`minOSChecked` 为真”才算完整，否则仍要探测，以补全缺失字段。

## 6. 逐个探测版本

`ASTCIdentifierResolver` 负责探测：

- **顺序：** 从新到旧。Apple 的数组是从旧到新，所以反向遍历。
- **并发：** 一次一个，每次间隔 0.15 秒，因为商店接口会限流。
- **上限：** 每次加载最多 60 个，避免一次探测上百次。剩余版本在之后打开时继续探测。
- **跳过：** 已完整的版本和 `skipped` 中的版本不探测。

### 单个版本的请求

`fetchBuildPlistForAdamID:externalID:identity:completion:` 按情况选择请求：

| 情况 | 请求 |
|---|---|
| 列表走了 Buy 回退 | 原生请求，把参数中的 `appExtVrsId` 换成目标版本，每个 App 每次列表查询最多 60 次 |
| 其他 | `buyProduct` 加 `appExtVrsId` |
| `buyProduct` 没有版本数据 | 改用 `MZFinance.woa/wa/volumeStoreDownloadProduct`（二进制 plist） |

### 解析响应

`resolveVersionForAdamID:externalID:pricingParameters:completion:` 读取 `songList` 的第一项：

1. 如果返回的版本 ID 与请求的不一致，视为 Apple 替换了版本，该版本不会进入列表。
2. 从 `metadata` 读取 `bundleShortVersionString`、`minimumOSVersion`、`bundleVersion`。
3. 如果没有版本号但有 IPA 地址，就读取 IPA 内的 `Info.plist`。

### 读取 IPA 中的最低系统版本

`metadata` 没有最低系统要求时，`ASTCPackageInfoReader` 用几次 HTTP Range 请求读取 IPA，不下载整个文件：

1. 读取 ZIP 末尾，定位中央目录。
2. 按每次 256 KiB 扫描中央目录，找到 `Payload/<name>.app/Info.plist`。
3. 只读取该条目并解压，取得 `MinimumOSVersion`。

这些请求发往 Apple 的 CDN，不受商店接口限流影响，所以与探测并行。IPA 地址有时效，不写入缓存。

### 探测的终止条件

| 情况 | 处理 |
|---|---|
| 成功 | 写入结果，清零连续拒绝计数 |
| 普通失败 | 记入 `skipped`，继续下一个 |
| 商店拒绝（`SSServerErrorDomain` 或错误码 11） | 本轮已有成功，或连续拒绝 2 次时，把更旧的版本全部记入 `skipped` 并结束 |
| 需要授权，或达到原生请求上限（错误码 15） | 立即结束，保留已有结果 |
| 版本列表已关闭 | 不再发新请求，已探测的结果写入缓存 |

列表被关闭、下滑关闭或从 App 选择页返回时，`viewDidDisappear:` 调用 `cancelVersionLookupForAdamID:`。查询 App 信息、检查安装状态、获取版本 ID 之后，以及每次探测之前，都会检查是否已取消。已发出的请求和正在进行的 `Info.plist` 读取会继续完成。

“拒绝后更旧的版本也不可用”基于 Apple 从最旧版本开始下架的判断。这是推测，没有官方依据。要求“本轮已成功或连续 2 次”，是为了不把账号未登录误判成版本下架。

## 7. 缓存与显示

缓存位于容器内的 `Library/Application Support/AppStoreControl/versions-<adamId>.plist`：

| 键 | 内容 |
|---|---|
| `identifiers` | Apple 返回的全部版本 ID |
| `resolved` | 版本 ID 对应的 `displayVersion`、`minimumOSVersion`、`bundleVersion`、`minOSChecked` |
| `skipped` | 放弃探测的版本 ID |

- **写入：** 先读取磁盘上的 `resolved` 再合并，避免多个列表同时写入时互相覆盖。
- **排序：** 按版本 ID 去重，再按版本号从新到旧排列。
- **已安装标记：** 优先比较版本 ID，因为版本号可能重复。取不到 ID 时才比较版本号。
- **下拉刷新：** 只清除 `skipped`，保留 `resolved`，因此一次失败的刷新不会清空列表。
- **清除缓存：** 长按账号按钮，选择 `Clear Version Cache`。

---

# 二、下载与安装

## 总流程

用户点击版本并确认后，调用 `-[ASTCInstaller installVersion:ofProduct:completion:]`：

```text
路径 1：本地重新下载参数
   ├─ 请求成功或没有响应 → 关闭版本列表，后台校验，最多 10 分钟，只写日志
   └─ 拿不到参数或请求报错
        ▼
路径 2：ASDPurchase 购买路径
        等待版本变化，180 秒未变则向用户报错
```

路径 1 的请求一旦成功或没有响应，就不再发第二次请求。下载可能已经开始，再发一次会造成重复下载。

点击 `Install` 后，该版本行右侧立刻显示 loading，期间点击其他版本不会有反应。请求失败时 loading 消失并弹出错误。

## 校验安装结果

`waitForInstalledVersion:bundleID:timeout:completion:` 每 3 秒通过 `ASDAppQuery` 查询一次已安装版本的 `storeExternalVersionID`，与目标 ID 相同才算成功。

校验只读取安装结果，**不能取消已发出的下载，也看不到下载进度**。所以大 App 还没装完，和请求根本没生效，对它来说是一样的：都是“版本还没变”。

因此校验结果的用途取决于路径：

| 路径 | 超时 | 结果用途 |
|---|---|---|
| 路径 1 | 600 秒 | 只写日志，不影响界面，也不触发其他请求 |
| 路径 2 | 180 秒 | 成功才关闭版本列表，否则弹出 `Install failed` |

## 路径 1：本地重新下载参数

入口是 `installVersionUsingLocalRedownloadParameters:forAdamID:bundleID:completion:`。**这是目前实测中真正完成安装的路径。**

1. **读取参数。** 通过 `ASDPurchaseHistory` 按账号和 `adamId` 查询购买记录，取匹配 bundle ID 的 `redownloadParams`。最多等 5 秒，取不到就转路径 2。
2. **改写版本。** `buyParameters:replacingExternalVersionID:` 把 `appExtVrsId` 换成目标 ID，没有该字段时追加。
3. **发送请求。** 用 `SSPurchaseRequest` 发送，配置如下：

| 对象 | 属性 | 值 | 作用 |
|---|---|---|---|
| `SSPurchase` | `createsDownloads`、`createsJobs`、`createsInstallJobs` | `YES` | 真正创建下载和安装任务 |
| `SSPurchase` | `usesLocalRedownloadParametersIfPossible` | `YES` | 使用本地重新下载身份 |
| `SSPurchase` | `preauthenticated`、`skipSoftwareAccountPreflight` | `YES` | 跳过账号预检 |
| `SSPurchase` | `displaysOnLockScreen` | `YES` | 在锁屏显示 |
| `SSPurchaseRequest` | `createsDownloads`、`createsJobs` | `YES` | 请求层的值会覆盖 purchase 的值 |
| `SSPurchaseRequest` | `needsAuthentication` | `NO` | 不要求认证 |
| `SSPurchaseRequest` | `backgroundRequest` | `YES` | 后台请求 |

Apple 接受后，系统的 App Store 下载流程接管，下载 Apple 签名的安装包并覆盖安装，App 数据保留。

这个请求带有 45 秒硬超时。超时后按“没有响应”处理，返回 `ASTCStoreNoResponseErrorCode`。Apple 可能已经收到请求，所以不转路径 2，只写日志，并按请求成功的流程继续。

## 路径 2：ASDPurchase 购买路径

入口是 `-[ASTCStoreServices installVersion:forAdamID:pricingParameters:completion:]`，这是最后的手段。代码注释说明它可能要求账号确认。

参数由 `ASTCBuildBuyParameters` 构造，`price=0`，`pricingParameters=STDQ`，`installed=0`，并带上 `ownerDsid` 和 `appExtVrsId`。

```text
productType=C&price=0&salableAdamId=<adamId>&pricingParameters=STDQ&pg=default
&clientBuyId=1&installed=0&ownerDsid=<dsid>&appExtVrsId=<ext>
```

`ASDPurchase` 设置 `createsJobs=YES`、`sendGUID=YES`，由 `-[ASDPurchaseManager startPurchase:withResultHandler:]` 发送。

如果系统没有 `ASDPurchase` 或 `ASDPurchaseManager`，或者无法发起请求，就退回旧的 `SSPurchaseRequest`，并使用 `createsDownloads=YES`。请求发起后，即使 Apple 没有下载，也不会走这条退路。

180 秒后版本仍不对时，向用户报错 `App Store accepted the download but the requested build did not install. Apple substituted a different build.`。这段文案的结论并不一定成立，也可能只是还没装完。

## 为什么不使用 ASDInstallApps

早期版本把 `+[ASDInstallApps installApp:withCompletionHandler:]` 放在第一位，传入 `ASDApp`。这种调用不可能生效：`_installApps:onPairedDevice:withCompletionHandler:` 只接受以下五种元数据类，而 `ASDApp` 不在其中。

- `ASDAppReviewAppMetadata`
- `ASDEnterpriseAppMetadata`
- `ASDSystemAppMetadata`
- `ASDTestFlightAppMetadata`
- `ASDWatchAppMetadata`

检查失败时，系统不会连接 appstored，而是直接以 `(nil, error)` 调用回调，错误码为 `0x38D`，描述为 `` `%@` is not available on this platform ``。

换成 `ASDAppReviewAppMetadata` 大概率也解决不了问题。它的字段里只有 `packageURL`，没有从商店下载用的参数，看起来是用来安装已有安装包的。

---

# 三、验证状态

## 已在设备上验证

环境：iOS 17.3，Dopamine RootHide 3，X（`333903271`）。

| 项目 | 结果 |
|---|---|
| 账号地区 | 账号地区和设备地区不同时，`SSDevice` 返回账号地区；此前因地区错误查不到的 NIKKE 恢复正常 |
| `SKStorefront.countryCode` | 返回三字母代码，确认不能用作 `cc` |
| 列表回退 | 取得 885 个版本 ID |
| 探测 | 60 次，0 次失败，用时约 103 秒 |
| 原生请求 | 61 次，0 次因价格中止，全程没有弹窗 |
| `ASDInstallApps` | 两次回调都返回 `(null)`，都没有效果。原因来自 AppStoreDaemon 的反汇编，设备上还没有打印实际错误 |
| 本地重新下载 | 从 12.39 降到 12.29（`891738139`），校验通过 |

这些结果来自调整安装顺序之前的版本。当时本地重新下载是在 `ASDInstallApps` 超时后才运行的。

调整安装顺序后的实测：

| 项目 | 结果 |
|---|---|
| 本地重新下载 | 从 12.29 升到 12.40（`894258476`），下载量约 249 MB，校验通过 |
| 请求次数 | 1 次 `local redownload install`，0 次 `ASDPurchase install` |
| 版本列表 | 请求返回后自动关闭 |
| `ASDAppQuery` 进度 | 单次查询就能读到 `progressPhase`、`progress`、`downloadProgress`、`installProgress`，不需要观察者 |

这次安装中读取到的进度：

| `progressPhase` | `placeholder` | `progress` | `downloadProgress` | `installProgress` |
|---|---|---|---|---|
| 0 | 0 | 无 | 无 | 无 |
| 2 | 1 | 0.056 → 0.582 | 9.5% → 97.1% | 0 |
| 3 | 1 | 0.600 | 100% | 0 |
| 4 | 1 | 0.760 | 100% | 0.400 |
| 0 | 0 | 无 | 无 | 无 |

`installID` 一直为空，`postProcessProgress` 一直是 `0/0`。`installProgress` 在 0.400 停留 30 多秒后，任务直接结束，不是连续变化。

## 未验证或仅为推测

- 其他 App 和其他账号的表现。上述安装结果只来自 X。
- Apple 是否会忽略 `appExtVrsId` 并返回其他版本。三次实测都拿到了正确版本。
- 路径 1 的 10 分钟校验超时和 45 秒无响应分支。
- 关闭版本列表后停止探测。
- `progressPhase` 各数值的含义。2 为下载、3 为下载完成、4 为安装，只是根据一次安装的数值变化推测的。
- 下载失败时 `progressPhase` 和 `installError` 的表现。
- 路径 2 在实测中没有运行。
- `ASDAppReviewAppMetadata` 是否必须提供 `packageURL`。这是根据字段和 AppStore++ 的用法得出的推断，没有反编译到 appstored 读取该字段的指令。
- 大 App 下载超过 2 分钟时不会重复请求。
- “被拒绝后更旧的版本也不可用”的判断。
- 响应中除 dialog 外的收费形式。当前只检查 `okButtonAction` 的价格。

---

# 四、已知问题

| # | 问题 | 影响 |
|---|---|---|
| 1 | 路径 1 校验发现版本不对时，只写日志 | Apple 替换版本或下载失败时，用户在界面上看不到提示 |
| 2 | 路径 1 请求 45 秒无响应时，列表也会关闭 | 请求其实失败时，用户只会看到没有开始下载 |
| 3 | loading 只在版本列表打开时阻止重复点击 | 关闭列表再打开后，仍可再次点击，发起多次安装 |
| 4 | Apple 替换版本和网络失败都会写入 `skipped` | 这些版本在下拉刷新前不会再探测 |
| 5 | 日志包含 `buyParams` 和账号标识 | 发布前需要移除或关闭 |
