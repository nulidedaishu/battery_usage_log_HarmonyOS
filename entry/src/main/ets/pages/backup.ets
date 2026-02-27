import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
/**
 * @file 本文件是电池监控应用的主页面实现。
 * 主要功能包括：
 * 1. 在应用启动时申请后台长时任务（LOCATION类型），以确保应用在后台能持续运行。
 * 2. 通过持续定位作为“保活”手段，维持后台任务的活跃状态。
 * 3. 定期（每500ms）获取设备的电池信息（电压、电流、电量）。
 * 4. 将获取到的电池信息以CSV格式追加写入到应用的私有目录下。
 * 5. 在应用退出时，妥善地停止后台任务和定位监听，释放资源。
 */

/**
 * 应用全局常量定义
 */
interface IConstants {
  readonly DOMAIN: number; // HiLog日志的领域标识
  readonly TAG: string; // HiLog日志的标签
  readonly LOCATION_PERMS: Array<Permissions>; // 需要申请的位置权限列表
  readonly LOG_INTERVAL_MS: number; // 电池信息记录的间隔时间（毫秒）
  readonly KEEP_ALIVE_LOCATION_INTERVAL_S: number; // 后台保活的定位信息更新间隔（秒）
  readonly LOG_FILE_NAME: string; // 日志文件的名称
  readonly EXPORT_FILE_NAME: string; // 导出日志时建议的文件名
  readonly LOG_FILE_HEADER: string; // CSV日志文件的表头
  readonly LOG_FILE_ACCESS_MODE: number; // 文件操作模式（读写、创建、追加）
  readonly PERMISSION_RETRY_COUNT: number; // (备用)权限申请重试次数
  readonly PERMISSION_RETRY_DELAY_MS: number; // (备用)权限申请重试延迟
}

const Constants: IConstants = {
  DOMAIN: 0x0000,
  TAG: '电池监视器',
  LOCATION_PERMS: ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'] as Array<Permissions>,
  LOG_INTERVAL_MS: 500,
  KEEP_ALIVE_LOCATION_INTERVAL_S: 600,
  LOG_FILE_NAME: 'battery_log.txt',
  EXPORT_FILE_NAME: '电池日志导出.txt',
  LOG_FILE_HEADER: "时间戳,电压(V),电流(mA),电量(%)\n",
  LOG_FILE_ACCESS_MODE: fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND,
  PERMISSION_RETRY_COUNT: 3,
  PERMISSION_RETRY_DELAY_MS: 1000
};


@Entry
@Component
struct Index {
  // =================================================================================
  // 状态变量与私有属性
  // =================================================================================

  // --- UI状态变量 ---
  @State voltage: number = 0; // 电池电压 (uV)，UI展示时会转换
  @State nowCurrent: number = 0; // 瞬时电流 (uA)
  @State batterySOC: number = 0; // 剩余电量百分比
  @State statusMessage: string = '正在监控电池状态...'; // 向用户展示当前应用状态
  @State isBusy: boolean = false; // 标志位，防止文件写入等耗时操作并发执行
  // --- 私有属性 ---
  /** UIAbility的上下文，用于获取应用信息、文件目录、发起权限请求等 */
  private context = getContext(this) as common.UIAbilityContext;
  /** 日志文件的完整路径 */
  private logFilePath: string = this.context.filesDir + `/${Constants.LOG_FILE_NAME}`;
  /** 日志文件的文件对象 */
  private logFile: fs.File | null = null;
  /** 定时器的ID，用于启动和停止周期性日志记录 */
  private intervalId: number = 0;

  // =================================================================================
  // 组件生命周期方法
  // =================================================================================

  /**
   * 组件即将显示时调用，是应用逻辑的入口。
   * 流程：
   * 1. 启动后台长时任务。
   * 2. 如果成功，则初始化日志文件。
   * 3. 启动周期性日志记录。
   * 4. 启动定位服务以实现后台保活。
   */
  async aboutToAppear() {
    hilog.info(Constants.DOMAIN, Constants.TAG, '页面即将显示，开始启动后台任务流程...');
    this.statusMessage = '正在申请后台权限...';

    const isLongTaskStarted = await this.startLongTermTask();
    if (isLongTaskStarted) {
      this.statusMessage = '后台任务已启动，正在监控电池...';
      hilog.info(Constants.DOMAIN, Constants.TAG, '长时任务启动成功，开始业务逻辑...');
      await this.setupLogging();
      this.startPeriodicLogging();
      this.ensureAndStartLocationKeepAlive();
    } else {
      this.statusMessage = '后台任务启动失败，应用可能无法在后台运行。';
      hilog.error(Constants.DOMAIN, Constants.TAG, '长时任务启动失败，后台功能受限。');
    }
  }

  /**
   * 组件即将销毁时调用，用于资源清理。
   * 流程：
   * 1. 停止定位保活。
   * 2. 停止后台长时任务。
   * 注意：日志定时器和文件句柄会随进程结束而自动释放，但显式停止后台任务是必要的。
   */
  async aboutToDisappear() {
    hilog.info(Constants.DOMAIN, Constants.TAG, '页面即将销毁，停止所有后台活动...');
    this.stopLocationKeepAlive();
    // 停止周期性日志记录
    if (this.intervalId !== 0) {
      clearInterval(this.intervalId);
      this.intervalId = 0;
      hilog.info(Constants.DOMAIN, Constants.TAG, '已停止周期性日志记录。');
    }
    // 关闭文件
    if (this.logFile) {
      await fs.close(this.logFile);
      this.logFile = null;
      hilog.info(Constants.DOMAIN, Constants.TAG, '已关闭日志文件。');
    }
    await this.stopLongTermTask();
  }

  // =================================================================================
  // 后台任务管理
  // =================================================================================

  /**
   * 启动后台长时任务。
   * 使用 LOCATION 类型的后台模式，这要求应用在配置文件中声明 `ohos.permission.LOCATION`，
   * 并且在运行时获得用户授权。
   * @returns {Promise<boolean>} 任务是否启动成功。
   */
  async startLongTermTask(): Promise<boolean> {
    try {
      // 创建一个WantAgent，当用户从通知栏点击时，可以拉起本应用
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name,
          },
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const wantAgentObj = await wantAgent.getWantAgent(wantAgentInfo);

      // 调用API启动后台运行
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.LOCATION,
        wantAgentObj);
      hilog.info(Constants.DOMAIN, Constants.TAG, 'backgroundTaskManager.startBackgroundRunning 调用成功');
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG, `申请长时任务失败: Code=${err.code}, Msg=${err.message}`);
      return false;
    }
  }

  /**
   * 停止后台长时任务。
   * 在应用退出或不再需要后台运行时调用，以节省系统资源。
   */
  async stopLongTermTask() {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      hilog.info(Constants.DOMAIN, Constants.TAG, '成功取消长时任务。');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG, `取消长时任务失败: Code=${err.code}, Msg=${err.message}`);
    }
  }

  // =================================================================================
  // 定位保活与权限管理
  // =================================================================================

  /** 持续定位请求的配置 */
  private locationRequest: geoLocationManager.ContinuousLocationRequest = {
    interval: Constants.KEEP_ALIVE_LOCATION_INTERVAL_S,
    locationScenario: geoLocationManager.UserActivityScenario.NAVIGATION
  };
  /**
   * 定位信息变化的回调函数。
   * 在此场景下，我们仅用它来维持后台任务的活跃状态，因此回调函数体可以为空或只打印日志。
   * @param location - 系统返回的位置信息对象。
   */
  private locationCallback: (location: geoLocationManager.Location) => void = (location) => {
    hilog.info(Constants.DOMAIN, Constants.TAG, 'locationCallback (保活): ' + JSON.stringify(location));
  };

  /**
   * 确保拥有定位权限并启动持续定位以实现保活。
   * 流程：
   * 1. 检查是否已授予定位权限。
   * 2. 若未授予，则向用户请求权限。
   * 3. 注册持续定位的回调。
   */
  private async ensureAndStartLocationKeepAlive() {
    try {
      const isGranted = await this.isAlreadyGranted();
      if (!isGranted) {
        hilog.info(Constants.DOMAIN, Constants.TAG, '定位权限不足，正在向用户请求...');
        const requestResult = await this.reqPermissionsFromUser(Constants.LOCATION_PERMS, this.context);
        if (!requestResult) {
          hilog.warn(Constants.DOMAIN, Constants.TAG, '用户未授予定位权限，后台保活可能失败。');
          this.statusMessage = '警告：未授予定位权限，后台可能无法运行。';
          return;
        }
      }
      // 注册定位回调
      geoLocationManager.on('locationChange', this.locationRequest, this.locationCallback);
      hilog.info(Constants.DOMAIN, Constants.TAG, '持续定位监听注册成功（用于保活）。');
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `启动保活定位失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 停止持续定位监听。
   * 在应用退出时调用，以避免不必要的电量消耗和资源占用。
   */
  private stopLocationKeepAlive() {
    try {
      geoLocationManager.off('locationChange', this.locationCallback);
      hilog.info(Constants.DOMAIN, Constants.TAG, '已取消持续定位监听。');
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `取消定位监听失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 检查应用是否已经被授予了必要的定位权限。
   * @returns {Promise<boolean>} 如果精确定位或模糊定位中至少有一个被授予，则返回true。
   */
  private async isAlreadyGranted(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo.accessTokenId;

      // 分别检查精确定位和模糊定位权限
      const grantLocation = await atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION');
      const grantApprox = await atManager.checkAccessToken(tokenId, 'ohos.permission.APPROXIMATELY_LOCATION');

      hilog.info(Constants.DOMAIN, Constants.TAG,
        `权限检查结果: LOCATION=${grantLocation}, APPROXIMATELY_LOCATION=${grantApprox}`);

      // 只要有一个权限被授予即可
      return grantLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ||
        grantApprox === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      const err = e as Error;
      hilog.error(Constants.DOMAIN, Constants.TAG,
        `权限校验异常: name=${err.name ?? 'unknown'}, message=${err.message ?? JSON.stringify(err)}`);
      return false;
    }
  }

  /**
   * 弹出对话框，向用户请求权限。
   * @param permissions - 需要请求的权限字符串数组。
   * @param context - UIAbility的上下文。
   * @returns {Promise<boolean>} 如果所有请求的权限都被用户授予，则返回true。
   */
  private reqPermissionsFromUser(permissions: Array<Permissions>, context: common.UIAbilityContext): Promise<boolean> {
    return new Promise((resolve) => {
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(context, permissions)
        .then((data) => {
          // 检查授权结果，0表示同意，非0表示拒绝
          const allGranted =
            data.authResults.every(result => result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
          if (allGranted) {
            hilog.info(Constants.DOMAIN, Constants.TAG, '所有请求的权限均已授权。');
            resolve(true);
          } else {
            hilog.warn(Constants.DOMAIN, Constants.TAG,
              `部分或全部权限被拒绝。AuthResults: ${JSON.stringify(data.authResults)}`);
            resolve(false);
          }
        })
        .catch((err: BusinessError) => {
          hilog.error(Constants.DOMAIN, Constants.TAG, `请求权限API调用失败: Code=${err.code}, Msg=${err.message}`);
          resolve(false);
        });
    });
  }

  // =================================================================================
  // 日志记录逻辑
  // =================================================================================

  /**
   * 初始化日志文件。
   * 如果文件不存在，则创建它并写入CSV表头。
   */
  async setupLogging() {
    try {
      // 以读写、创建、追加模式打开文件
      const file = await fs.open(this.logFilePath, Constants.LOG_FILE_ACCESS_MODE);
      const stat = await fs.stat(this.logFilePath);
      // 如果文件是新创建的（大小为0），则写入CSV头部
      if (stat.size === 0) {
        await fs.write(file.fd, Constants.LOG_FILE_HEADER);
        hilog.info(Constants.DOMAIN, Constants.TAG, '新日志文件，已写入CSV表头。');
      }
      this.logFile = file;
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志文件设置成功: ${this.logFilePath}`);
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `设置日志失败: ${JSON.stringify(err)}`);
      this.statusMessage = '错误：无法初始化日志文件。';
    }
  }

  /**
   * 启动一个定时器，周期性地调用 `writeBatteryInfo` 方法。
   */
  startPeriodicLogging() {
    if (this.intervalId !== 0) {
      hilog.warn(Constants.DOMAIN, Constants.TAG, '日志定时器已在运行中，无需重复启动。');
      return;
    }
    hilog.info(Constants.DOMAIN, Constants.TAG, `启动周期性日志记录 (每${Constants.LOG_INTERVAL_MS}毫秒一次)...`);
    this.intervalId = setInterval(() => {
      this.writeBatteryInfo();
    }, Constants.LOG_INTERVAL_MS);
  }

  /**
   * 获取当前电池信息并将其写入日志文件。
   */
  async writeBatteryInfo() {
    // 如果文件未准备好或正在进行其他操作，则跳过此次写入
    if (!this.logFile || this.isBusy) {
      if (this.isBusy) {
        hilog.warn(Constants.DOMAIN, Constants.TAG, '系统正忙于文件操作，跳过此次写入。');
      }
      return;
    }

    try {
      // 从batteryInfo模块同步获取电池数据
      const currentVoltage = batteryInfo.voltage;
      const currentNowCurrent = batteryInfo.nowCurrent;
      const currentBatterySOC = batteryInfo.batterySOC;

      // 更新UI状态变量
      this.voltage = currentVoltage;
      this.nowCurrent = currentNowCurrent;
      this.batterySOC = currentBatterySOC;

      // 格式化时间戳和数据为CSV行
      const beijingTime = new Date();
      const formattedTime =
        `${(beijingTime.getMonth() + 1).toString().padStart(2, '0')}-` +
          `${beijingTime.getDate().toString().padStart(2, '0')} ` +
          `${beijingTime.getHours().toString().padStart(2, '0')}:` +
          `${beijingTime.getMinutes().toString().padStart(2, '0')}:` +
          `${beijingTime.getSeconds().toString().padStart(2, '0')}.` +
          `${beijingTime.getMilliseconds().toString().padStart(3, '0')}`;
      const logEntry =
        `"${formattedTime}",${(currentVoltage / 1000000).toFixed(2)},${currentNowCurrent},${currentBatterySOC}\n`;

      // 异步写入文件
      await fs.write(this.logFile.fd, logEntry);
      // 将写入的内容打印到hilog上
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志写入成功: ${logEntry.trim()}`);
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `日志写入失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * [新增] 导出内部日志文件到公共的Download目录。
   * 使用 DocumentPicker 的 DOWNLOAD 模式，该模式会自动在系统的 "Download" 文件夹下
   * 创建一个以应用包名命名的子目录，并将文件保存在其中，全程无需用户交互。
   * @returns {Promise<boolean>} 导出的操作是否成功。
   */
  async exportLogToDownload(): Promise<boolean> {
    if (this.isBusy) {
      hilog.warn(Constants.DOMAIN, Constants.TAG, '正忙于其他操作，请稍后重试导出。');
      this.statusMessage = '系统正忙，请稍后重试';
      return false;
    }
    this.isBusy = true;
    this.statusMessage = '正在准备导出...';
    hilog.info(Constants.DOMAIN, Constants.TAG, '开始导出日志文件...');
    try {
      // 步骤 1: 检查源日志文件是否存在
      try {
        await fs.access(this.logFilePath);
      } catch (e) {
        hilog.error(Constants.DOMAIN, Constants.TAG, `源日志文件不存在: ${this.logFilePath}`);
        this.statusMessage = '错误：日志文件不存在，无法导出。';
        return false; // 直接返回，因为没有文件可以导出
      }
      // 步骤 2: 使用 DOWNLOAD 模式获取目标保存目录的URI
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      // 设置为DOWNLOAD模式，将直接保存到 Download/包名/ 目录下
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const documentSaveResult = await documentViewPicker.save(documentSaveOptions);
      // 返回的是一个目录的URI
      const targetDirectoryUri = documentSaveResult[0];
      hilog.info(Constants.DOMAIN, Constants.TAG, `成功获取下载目录URI: ${targetDirectoryUri}`);
      // 步骤 3: 读取源日志文件的全部内容
      this.statusMessage = '正在读取日志...';
      const logContent = await fs.readText(this.logFilePath);
      // 步骤 4: 构建目标文件的完整路径并写入内容
      this.statusMessage = '正在写入文件...';
      // 将文件名拼接到目录URI后，并使用 fileUri.FileUri 转换为fs模块可用的标准路径
      const targetFilePath = new fileUri.FileUri(targetDirectoryUri + '/' + Constants.EXPORT_FILE_NAME).path;
      const targetFile = await fs.open(targetFilePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(targetFile.fd, logContent);
      await fs.close(targetFile);
      // 步骤 5: 成功反馈
      const successMessage =
        `导出成功！\n请在 "文件管理器 > Download > ${this.context.abilityInfo.bundleName}" 目录中查看。`;
      this.statusMessage = successMessage;
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志成功导出到: ${targetFilePath}`);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG, `导出日志失败: Code=${err.code}, Msg=${err.message}`);
      this.statusMessage = `导出失败: ${err.message}`;
      return false;
    } finally {
      // 确保 isBusy 状态被重置
      this.isBusy = false;
    }
  }

  async clearLog() {
    await fs.unlink(this.logFilePath);
    await this.setupLogging();
  }

  /**
   * [新增] 在hilog中打印日志文件的内容。
   * 用于调试和验证日志写入是否正确。
   */
  async printLogToHilog() {
    if (this.isBusy) {
      hilog.warn(Constants.DOMAIN, Constants.TAG, '正忙于其他操作，请稍后重试打印日志。');
      this.statusMessage = '系统正忙，请稍后重试';
      return;
    }
    this.isBusy = true;
    this.statusMessage = '正在读取日志...';
    hilog.info(Constants.DOMAIN, Constants.TAG, '开始读取并打印日志文件内容...');
    try {
      // 检查源日志文件是否存在
      try {
        await fs.access(this.logFilePath);
      } catch (e) {
        hilog.error(Constants.DOMAIN, Constants.TAG, `源日志文件不存在: ${this.logFilePath}`);
        this.statusMessage = '错误：日志文件不存在，无法打印。';
        return;
      }

      // 读取日志文件内容
      const logContent = await fs.readText(this.logFilePath);
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志文件内容:\n${logContent}`);
      this.statusMessage = '日志内容已打印到hilog。';
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG, `读取日志失败: Code=${err.code}, Msg=${err.message}`);
      this.statusMessage = `读取日志失败: ${err.message}`;
    } finally {
      this.isBusy = false;
    }
  }

  build() {
    Row() {
      Column() {
        Text('鸿蒙电池监视器')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 20 })
          .fontColor(Color.Black)

        Text(`电压: ${(this.voltage / 1000000).toFixed(2)} V`)
          .fontSize(18)
          .margin({ bottom: 10 })
          .fontColor(Color.Black)

        Text(`瞬时电流: ${this.nowCurrent} mA`)
          .fontSize(18)
          .margin({ bottom: 10 })
          .fontColor(Color.Black)

        Text(`电量: ${this.batterySOC}%`)
          .fontSize(18)
          .margin({ bottom: 30 })
          .fontColor(Color.Black)

        // 按钮在繁忙时禁用，防止用户重复点击
        Button('导出日志')
          .onClick(() => this.exportLogToDownload())
          .enabled(!this.isBusy) // 关键改动
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0x317AF7)
          .opacity(this.isBusy ? 0.5 : 1.0) // 视觉反馈

        Button('清空日志')
          .onClick(() => this.clearLog())
          .enabled(!this.isBusy) // 关键改动
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0xFF6347)
          .opacity(this.isBusy ? 0.5 : 1.0) // 视觉反馈

        Button('打印日志')
          .onClick(() => this.printLogToHilog())
          .enabled(!this.isBusy) // 关键改动
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0xFF6347)
          .opacity(this.isBusy ? 0.5 : 1.0) // 视觉反馈

        Text(this.statusMessage)
          .fontSize(14)
          .fontColor(Color.Gray)
          .margin({ top: 10 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .height('100%')
    .backgroundColor(0xF1F3F5)
  }
}
