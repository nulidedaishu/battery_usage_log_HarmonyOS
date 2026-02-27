import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const ABILITY_TAG = 'EntryAbility'; // Ability级日志标签

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    // 使用明确定义的ABILITY_TAG常量
    hilog.info(DOMAIN, ABILITY_TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Third', (err) => {
    // windowStage.loadContent('pages/Forth', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      windowStage.getMainWindow((err, windowClass) => {
        windowClass.setWindowLayoutFullScreen(true)
        windowClass.setWindowSystemBarEnable(['navigation'])
        let isKeepScreenOn: boolean = true;
        try {
          let promise = windowClass.setWindowKeepScreenOn(isKeepScreenOn);
          promise.then(() => {
            console.info('Succeeded in setting the screen to be always on.');
          }).catch((err: BusinessError) => {
            console.error(`Failed to set the screen to be always on. Cause code: ${err.code}, message: ${err.message}`);
          });
        } catch (exception) {
          console.error(`Failed to set the screen to be always on. Cause code: ${exception.code}, message: ${exception.message}`);
        }
      })

      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  // onForeground(): void {
  //   // Ability has brought to foreground
  //   hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  // }
  //
  // onBackground(): void {
  //   // Ability has back to background
  //   hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  // }

  onBackground(): void {
    // 使用明确定义的ABILITY_TAG常量
    hilog.info(DOMAIN, ABILITY_TAG, 'Ability进入后台，保持电池监测');
    // 此处不停止任务，保持后台运行
  }

  onForeground(): void {
    // 使用明确定义的ABILITY_TAG常量
    hilog.info(DOMAIN, ABILITY_TAG, 'Ability回到前台');
    // 恢复UI更新等操作
  }
}