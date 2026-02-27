import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs, picker,fileUri } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';

interface IConstants {
  readonly DOMAIN: number;
  readonly TAG: string;
  readonly LOCATION_PERMS: Array<Permissions>;
  readonly LOG_INTERVAL_MS: number;
  readonly KEEP_ALIVE_LOCATION_INTERVAL_S: number;
  readonly LOG_FILE_NAME: string;
  readonly EXPORT_FILE_NAME: string;
}

// --- 优化 1: 集中管理常量 ---
const Constants: IConstants = {
  DOMAIN: 0x0000,
  TAG: '电池监视器', // TAG也改为中文，方便过滤
  LOCATION_PERMS: ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'] as Array<Permissions>,
  LOG_INTERVAL_MS: 500, // 日志记录间隔调整为5秒
  KEEP_ALIVE_LOCATION_INTERVAL_S: 600, // 保活定位间隔调整为10分钟
  LOG_FILE_NAME: 'battery_log.txt',
  EXPORT_FILE_NAME: '电池日志导出.csv' // 导出文件名也中文化
};

@Entry
@Component
struct Index {
  // UI相关的状态变量
  @State voltage: number = 0;
  @State nowCurrent: number = 0;
  @State batterySOC: number = 0;
  @State statusMessage: string = '正在初始化...';
  // 内部属性
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private logFilePath: string = '';
  private logFileStream: fs.Stream | null = null;
  private intervalId: number = 0;
  private locationRequest: geoLocationManager.ContinuousLocationRequest = {
    interval: Constants.KEEP_ALIVE_LOCATION_INTERVAL_S,
    locationScenario: geoLocationManager.UserActivityScenario.NAVIGATION
  };
  private locationCallback: (location: geoLocationManager.Location) => void = (location) => {
    hilog.info(Constants.DOMAIN, Constants.TAG, `接收到保活定位信息: ${JSON.stringify(location)}`);
  };

  async aboutToAppear() {
    hilog.info(Constants.DOMAIN, Constants.TAG, '页面即将显示，开始后台任务流程...');
    this.logFilePath = `${this.context.filesDir}/${Constants.LOG_FILE_NAME}`;

    this.statusMessage = '申请后台运行权限...';
    const isLongTaskStarted = await this.startLongTermTask();
    if (isLongTaskStarted) {
      this.statusMessage = '后台任务已启动，正在监控电池...';
      hilog.info(Constants.DOMAIN, Constants.TAG, '长时任务启动成功。');
      await this.setupLogging();
      await this.ensureAndStartLocationKeepAlive();
    } else {
      this.statusMessage = '后台任务启动失败，应用可能无法在后台运行。';
      hilog.error(Constants.DOMAIN, Constants.TAG, '启动长时任务失败。');
    }
  }

  async aboutToDisappear() {
    hilog.info(Constants.DOMAIN, Constants.TAG, '页面即将消失，正在停止所有活动...');
    this.cleanupLogging();
    this.stopLocationKeepAlive();
    await this.stopLongTermTask();
  }

  // --- 后台任务管理 ---
  async startLongTermTask(): Promise<boolean> {
    try {
      let wantAgentInfo: wantAgent.WantAgentInfo = {
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
      hilog.info(Constants.DOMAIN, Constants.TAG, 'backgroundTaskManager.startBackgroundRunning 调用成功。');
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG,
        `请求长时任务失败：错误码=${err.code}, 信息=${err.message}`);
      return false;
    }
  }

  async stopLongTermTask() {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      hilog.info(Constants.DOMAIN, Constants.TAG, '成功停止长时任务。');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(Constants.DOMAIN, Constants.TAG,
        `停止长时任务失败：错误码=${err.code}, 信息=${err.message}`);
    }
  }

  // --- 日志记录模块 ---
  async setupLogging() {
    try {
      hilog.info(Constants.DOMAIN, Constants.TAG, `准备打开日志文件流: ${this.logFilePath}`);
      this.logFileStream = await fs.createStream(this.logFilePath, 'a+');
      hilog.info(Constants.DOMAIN, Constants.TAG, '日志文件流打开成功。');
      this.startPeriodicLogging();
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `设置日志记录失败: ${JSON.stringify(err)}`);
    }
  }

  startPeriodicLogging() {
    if (this.intervalId !== 0) {
      return;
    }
    hilog.info(Constants.DOMAIN, Constants.TAG,
      `开始周期性日志记录 (每 ${Constants.LOG_INTERVAL_MS / 1000} 秒)...`);
    this.intervalId = setInterval(() => {
      this.writeBatteryInfo();
    }, Constants.LOG_INTERVAL_MS);
  }

  async writeBatteryInfo() {
    if (!this.logFileStream) {
      hilog.warn(Constants.DOMAIN, Constants.TAG, '日志流未准备就绪，跳过本次写入。');
      return;
    }
    try {
      // 更新UI状态
      this.voltage = batteryInfo.voltage;
      this.nowCurrent = batteryInfo.nowCurrent;
      this.batterySOC = batteryInfo.batterySOC;

      const beijingTime = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
      const logEntry = `${beijingTime},${(this.voltage / 1000000)},${this.nowCurrent},${this.batterySOC}\n`;

      await this.logFileStream.write(logEntry);
      // 【关键修改】将写入的日志内容也打印到 hilog，方便实时调试
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志条目写入成功: ${logEntry.trim()}`);
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `写入日志失败: ${JSON.stringify(err)}`);
    }
  }

  cleanupLogging() {
    if (this.intervalId !== 0) {
      clearInterval(this.intervalId);
      this.intervalId = 0;
      hilog.info(Constants.DOMAIN, Constants.TAG, '周期性日志记录已停止。');
    }
    if (this.logFileStream) {
      this.logFileStream.close().then(() => {
        hilog.info(Constants.DOMAIN, Constants.TAG, '日志文件流关闭成功。');
        this.logFileStream = null;
      }).catch((err: Error) => {
        hilog.error(Constants.DOMAIN, Constants.TAG, `关闭日志流失败: ${JSON.stringify(err)}`);
      });
    }
  }

  // --- 日志导出 ---
  async exportLogToDownload() {
    this.statusMessage = '正在导出...';
    try {
      try {
        await fs.access(this.logFilePath);
      } catch (e) {
        this.statusMessage = '没有日志可以导出。';
        hilog.error(Constants.DOMAIN, Constants.TAG, '日志文件不存在，无法导出。');
        return;
      }

      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.newFileNames = [Constants.EXPORT_FILE_NAME];
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.save(documentSaveOptions);

      if (!uris || uris.length === 0) {
        this.statusMessage = '导出已取消。';
        hilog.warn(Constants.DOMAIN, Constants.TAG, '用户取消了导出或未能获取到URI。');
        return;
      }
      const targetUri = uris[0];

      await fs.copyFile(this.logFilePath, targetUri);

      this.statusMessage = `导出成功!`;
      hilog.info(Constants.DOMAIN, Constants.TAG, `日志成功导出至: ${targetUri}`);

    } catch (error) {
      const err = error as BusinessError;
      this.statusMessage = `导出失败: ${err.message}`;
      hilog.error(Constants.DOMAIN, Constants.TAG, `导出失败: 错误码=${err.code}, 信息=${err.message}`);
    }
  }

  // --- 权限管理 ---
  private async ensureAndStartLocationKeepAlive() {
    try {
      const isGranted = await this.isAlreadyGranted();
      if (!isGranted) {
        const requestResult = await this.reqPermissionsFromUser(Constants.LOCATION_PERMS, this.context);
        if (!requestResult) {
          hilog.warn(Constants.DOMAIN, Constants.TAG, '定位权限被拒绝。后台保活可能无法正常工作。');
          this.statusMessage = '警告：缺少定位权限，后台保活可能失败。';
          return;
        }
      }
      geoLocationManager.on('locationChange', this.locationRequest, this.locationCallback);
      hilog.info(Constants.DOMAIN, Constants.TAG, '已为后台保活注册持续定位监听器。');
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `启动定位保活失败: ${JSON.stringify(err)}`);
    }
  }

  private stopLocationKeepAlive() {
    try {
      geoLocationManager.off('locationChange', this.locationCallback);
      hilog.info(Constants.DOMAIN, Constants.TAG, '已取消持续定位监听器。');
    } catch (err) {
      hilog.error(Constants.DOMAIN, Constants.TAG, `取消定位监听器失败: ${JSON.stringify(err)}`);
    }
  }

  private async isAlreadyGranted(): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    const bundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId = bundleInfo.appInfo.accessTokenId;
    const grantStatus = await atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION');
    return grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  private reqPermissionsFromUser(permissions: Array<Permissions>, context: common.UIAbilityContext): Promise<boolean> {
    return new Promise((resolve) => {
      abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
        .then((data) => {
          const isGranted =
            data.authResults.every(result => result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
          resolve(isGranted);
        })
        .catch((err: BusinessError) => {
          hilog.error(Constants.DOMAIN, Constants.TAG,
            `权限请求失败: 错误码=${err.code}, 信息=${err.message}`);
          resolve(false);
        });
    });
  }

  // --- 日志清理 ---
  async clearAndResetLog() {
    hilog.info(Constants.DOMAIN, Constants.TAG, '正在清空并重置日志...');
    this.statusMessage = '正在清空日志...';
    this.cleanupLogging();

    try {
      await new Promise<void>(resolve => setTimeout(resolve, 100));
      await fs.unlink(this.logFilePath);
      hilog.info(Constants.DOMAIN, Constants.TAG, `旧日志文件已删除: ${this.logFilePath}`);
    } catch (err) {
      hilog.warn(Constants.DOMAIN, Constants.TAG,
        `日志文件可能不存在，无需删除: ${JSON.stringify(err)}`);
    }
    await this.setupLogging();
    this.statusMessage = '日志已清空，开始新的记录。';
    hilog.info(Constants.DOMAIN, Constants.TAG, '日志重置完成。');
  }

  build() {
    Row() {
      Column() {
        Text('鸿蒙电池监视器')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 20 })

        Text(`电压: ${(this.voltage / 1000000).toFixed(2)} V`)
          .fontSize(18)
          .margin({ bottom: 10 })

        Text(`瞬时电流: ${this.nowCurrent} mA`)
          .fontSize(18)
          .margin({ bottom: 10 })

        Text(`剩余电量: ${this.batterySOC} %`) // 添加了电量显示
          .fontSize(18)
          .margin({ bottom: 30 })

        Button('导出日志')
          .onClick(() => this.exportLogToDownload())
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor($r('app.color.brand_color', 0x317AF7))

        Button('清空日志')
          .onClick(() => this.clearAndResetLog())
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor($r('app.color.danger_color', 0xFF6347))

        Text(this.statusMessage)
          .fontSize(14)
          .fontColor(Color.Gray)
          .margin({ top: 10 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding(20)
    }
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
