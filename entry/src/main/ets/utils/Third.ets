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
  readonly LOG_FILE_NAME: string; // 日志文件的名称
  readonly EXPORT_FILE_NAME: string; // 导出日志时建议的文件名
  readonly LOG_FILE_HEADER: string; // CSV日志文件的表头
  readonly LOG_FILE_ACCESS_MODE: number; // 文件操作模式（读写、创建、追加）
  readonly DOWNLOAD_FILE_ACCESS_MODE: number; // 文件操作模式（读写、创建、覆盖）
}

const Constants: IConstants = {
  LOG_FILE_NAME: 'battery_log.txt',
  EXPORT_FILE_NAME: '电池日志导出.txt',
  LOG_FILE_HEADER: "abcdefg\n",
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
  /** 标志位，防止文件导出等耗时操作并发执行 */
  @State isBusy: boolean = false;
  // --- 私有属性 ---
  /** UIAbility的上下文，用于获取应用信息、文件目录、发起权限请求等 */
  private context = getContext(this) as common.UIAbilityContext;
  /** 日志文件的完整路径 */
  private logFilePath: string = `${this.context.filesDir}/${Constants.LOG_FILE_NAME}`;


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
    await this.setupLogging();
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

  // =================================================================================
  // UI 构建
  // =================================================================================

  /**
   * 构建页面的UI布局。
   */
  build() {
    Row() {
      Column() {
        Button('导出')
          .onClick(() => this.exportLogToDownload())
          .enabled(!this.isBusy)
          .margin({ bottom: 15 })
          .width('80%')
          .height(50)
          .backgroundColor(0x000000)
          .opacity(this.isBusy ? 0.5 : 1.0)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .height('100%')
    .backgroundColor(0x000000)
  }
}
