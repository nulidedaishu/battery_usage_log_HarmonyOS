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
 * 应用全局常量接口
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
  readonly DOWNLOAD_FILE_ACCESS_MODE: number; // 文件操作模式（读写、创建、覆盖）
}

const Constants: IConstants = {
  DOMAIN: 0x0000,
  TAG: '电池监视器',
  LOCATION_PERMS: ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'] as Array<Permissions>,
  LOG_INTERVAL_MS: 500,
  KEEP_ALIVE_LOCATION_INTERVAL_S: 60,
  LOG_FILE_NAME: 'battery_log.txt',
  EXPORT_FILE_NAME: '电池日志导出.txt',
  LOG_FILE_HEADER: "时间戳,电压(V),电流(mA),电量(%)\n",
  LOG_FILE_ACCESS_MODE: fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND,
  DOWNLOAD_FILE_ACCESS_MODE: fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC,
};


@Entry
@Component
  /**
   * 电池监控应用的主页面组件
   */
struct Index {
  // =================================================================================
  // 属性定义
  // =================================================================================

  // --- UI状态变量 ---
  /** 电池电压 (uV)，UI展示时会转换为V */
  @State voltage: number = 0;
  /** 瞬时电流 (mA) */
  @State nowCurrent: number = 0;
  /** 剩余电量百分比 */
  @State batterySOC: number = 0;
  /** 标志位，防止文件导出等耗时操作并发执行 */
  @State isBusy: boolean = false;
  // --- 私有属性 ---
  /** UIAbility的上下文，用于获取应用信息、文件目录、发起权限请求等 */
  private context = getContext(this) as common.UIAbilityContext;
  /** 日志文件的完整路径 */
  private logFilePath: string = `${this.context.filesDir}/${Constants.LOG_FILE_NAME}`;
  /** 日志文件的文件对象 */
  private logFile: fs.File | null = null;
  /** 定时器的ID，用于启动和停止周期性日志记录 */
  private intervalId: number = 0;

  // =================================================================================
  // 组件生命周期
  // =================================================================================

  /**
   * 组件即将显示时调用，是应用核心逻辑的入口。
   * 流程：
   * 1. 启动后台长时任务。
   * 2. 初始化日志文件。
   * 3. 启动周期性日志记录。
   * 4. 启动定位服务以实现后台保活。
   */
  async aboutToAppear() {
    await this.startLongTermTask();
    await this.setupLogging();
    this.startPeriodicLogging();
    this.ensureAndStartLocationKeepAlive();
  }

  /**
   * 组件即将销毁时调用，用于清理所有资源。
   * 流程：
   * 1. 停止定位保活。
   * 2. 停止周期性日志记录。
   * 3. 关闭日志文件。
   * 4. 停止后台长时任务。
   */
  async aboutToDisappear() {
    this.stopLocationKeepAlive();
    if (this.intervalId !== 0) {
      clearInterval(this.intervalId);
      this.intervalId = 0;
    }
    if (this.logFile) {
      await fs.close(this.logFile);
      this.logFile = null;
    }
    await this.stopLongTermTask();
  }

  // =================================================================================
  // 后台任务管理
  // =================================================================================

  /**
   * 启动后台长时任务。
   * 使用 LOCATION 类型的后台模式，要求应用在配置文件中声明并获得用户授权。
   * @returns {Promise<boolean>} 任务是否启动成功。
   */
  async startLongTermTask(): Promise<boolean> {
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name,
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const wantAgentObj = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.LOCATION,
        wantAgentObj);
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * 停止后台长时任务，以节省系统资源。
   */
  async stopLongTermTask() {
    await backgroundTaskManager.stopBackgroundRunning(this.context);
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
   * 定位信息变化的回调函数，仅用于维持后台任务活跃。
   * @param location - 系统返回的位置信息对象。
   */
  private locationCallback: (location: geoLocationManager.Location) => void = (location) => {
    location;
  };

  /**
   * 确保拥有定位权限并启动持续定位以实现后台保活。
   */
  private async ensureAndStartLocationKeepAlive() {
    const isGranted = await this.isAlreadyGranted();
    if (!isGranted) {
      const requestResult = await this.reqPermissionsFromUser(Constants.LOCATION_PERMS, this.context);
      if (!requestResult) {
        return;
      }
    }
    geoLocationManager.on('locationChange', this.locationRequest, this.locationCallback);
  }

  /**
   * 停止持续定位监听，避免不必要的电量消耗。
   */
  private stopLocationKeepAlive() {
    geoLocationManager.off('locationChange', this.locationCallback);
  }

  /**
   * 检查应用是否已被授予必要的定位权限。
   * @returns {Promise<boolean>} 如果精确定位或模糊定位中至少有一个被授予，则返回true。
   */
  private async isAlreadyGranted(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const grantLocation = await atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION');
      const grantApprox = await atManager.checkAccessToken(tokenId, 'ohos.permission.APPROXIMATELY_LOCATION');
      return grantLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ||
        grantApprox === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
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
      abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
        .then((data) => {
          const allGranted =
            data.authResults.every(result => result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
          if (allGranted) {
            resolve(true);
          } else {
            resolve(false);
          }
        })
        .catch(() => {
          resolve(false);
        });
    });
  }

  // =================================================================================
  // 日志记录逻辑
  // =================================================================================

  /**
   * 初始化日志文件。如果文件不存在，则创建它并写入CSV表头。
   */
  async setupLogging() {
    const file = await fs.open(this.logFilePath, Constants.LOG_FILE_ACCESS_MODE);
    const stat = await fs.stat(this.logFilePath);
    if (stat.size === 0) {
      await fs.write(file.fd, Constants.LOG_FILE_HEADER);
    }
    this.logFile = file;
  }

  /**
   * 启动定时器，周期性地记录电池信息。
   */
  startPeriodicLogging() {
    if (this.intervalId !== 0) {
      return;
    }
    this.intervalId = setInterval(() => {
      this.writeBatteryInfo();
    }, Constants.LOG_INTERVAL_MS);
  }

  /**
   * 获取当前电池信息并将其追加写入日志文件。
   */
  async writeBatteryInfo() {
    if (!this.logFile || this.isBusy) {
      return;
    }
    this.voltage = batteryInfo.voltage;
    this.nowCurrent = batteryInfo.nowCurrent;
    this.batterySOC = batteryInfo.batterySOC;
    const beijingTime = new Date();
    const formattedTime = `${(beijingTime.getMonth() + 1).toString().padStart(2, '0')}-` +
      `${beijingTime.getDate().toString().padStart(2, '0')} ` +
      `${beijingTime.getHours().toString().padStart(2, '0')}:` +
      `${beijingTime.getMinutes().toString().padStart(2, '0')}:` +
      `${beijingTime.getSeconds().toString().padStart(2, '0')}.` +
      `${beijingTime.getMilliseconds().toString().padStart(3, '0')}`;
    const logEntry =
      `"${formattedTime}",${(batteryInfo.voltage /
        1000000).toFixed(2)},${batteryInfo.nowCurrent},${batteryInfo.batterySOC}\n`;
    await fs.write(this.logFile.fd, logEntry);
  }

  // =================================================================================
  // 文件操作与UI交互
  // =================================================================================

  /**
   * 导出内部日志文件到公共的Download目录。
   * 使用 DocumentPicker 的 DOWNLOAD 模式，无需用户交互即可保存。
   * @returns {Promise<boolean>} 导出操作是否成功。
   */
  async exportLogToDownload(): Promise<boolean> {
    if (this.isBusy) {
      return false;
    }
    this.isBusy = true;
    try {
      await fs.access(this.logFilePath);
      const logContent = await fs.readText(this.logFilePath);
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const documentSaveResult = await documentViewPicker.save(documentSaveOptions);
      const targetDirectoryUri = documentSaveResult[0];
      const targetFilePath = new fileUri.FileUri(`${targetDirectoryUri}/${Constants.EXPORT_FILE_NAME}`).path;
      const targetFile = await fs.open(targetFilePath, Constants.DOWNLOAD_FILE_ACCESS_MODE);
      await fs.write(targetFile.fd, logContent);
      await fs.close(targetFile);
      return true;
    } catch (error) {
      return false;
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 清空内部日志文件内容，并重新写入表头。
   */
  async clearLog() {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await fs.unlink(this.logFilePath);
      await this.setupLogging();
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 在hilog中打印日志文件的全部内容，用于调试。
   */
  async printLogToHilog() {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await fs.access(this.logFilePath);
      const logContent = await fs.readText(this.logFilePath);
      hilog.info(Constants.DOMAIN, Constants.TAG,
        `====== 日志文件内容 START ======\n${logContent}\n====== 日志文件内容 END ======`);
    } finally {
      this.isBusy = false;
    }
  }

  // =================================================================================
  // UI 构建
  // =================================================================================

  /**
   * 构建页面的UI布局。
   */
  build() {
    Row() {
      Column() {
        Text(`电压: ${(this.voltage / 1000000).toFixed(2)} V`)
          .fontSize(18)
          .fontColor(0xFFFFFF)
          .margin({ bottom: 10 })

        Text(`电流: ${this.nowCurrent} mA`)
          .fontSize(18)
          .fontColor(0xFFFFFF)
          .margin({ bottom: 10 })

        Text(`电量: ${this.batterySOC}%`)
          .fontSize(18)
          .fontColor(0xFFFFFF)
          .margin({ bottom: 30 })

        Button('导出日志')
          .onClick(() => this.exportLogToDownload())
          .enabled(!this.isBusy)
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0x000000)
          .opacity(this.isBusy ? 0.5 : 1.0)

        Button('清空日志')
          .onClick(() => this.clearLog())
          .enabled(!this.isBusy)
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0x000000)
          .opacity(this.isBusy ? 0.5 : 1.0)

        // Button('打印日志')
        //   .onClick(() => this.printLogToHilog())
        //   .enabled(!this.isBusy)
        //   .margin({ bottom: 15 })
        //   .width('80%')
        //   .height(50)
        //   .backgroundColor(0x000000)
        //   .opacity(this.isBusy ? 0.5 : 1.0)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .height('100%')
    .backgroundColor(0x000000)
  }
}
