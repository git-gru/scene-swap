//
//  AppDelegate.swift
//  SceneSwap
//
//  Created by Rizwan on 3/15/18.
//  Copyright © 2018 Rizwan. All rights reserved.
//

import UIKit
import LGSideMenuController
import WatchdogInspector

let storyBoardMain = UIStoryboard(name: "Main", bundle: nil)
let app = UIApplication.shared.delegate as! AppDelegate
let topMenu = storyBoardMain.instantiateViewController(withIdentifier: "TopMenuController") as! TopMenuController
@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
//        RRFPSBar.sharedInstance().isHidden = false
//        fpsStart()
        setMenu()
        return true
    }
    
    func fpsStart(){
        TWWatchdogInspector.start()
    }
    func fpsStop(){
        TWWatchdogInspector.stop()
    }
    
    func setMenu(){
        
        self.window = UIWindow(frame: UIScreen.main.bounds)
        
        let rootViewController = storyBoardMain.instantiateViewController(withIdentifier: "ViewController")
        let leftViewController = storyBoardMain.instantiateViewController(withIdentifier: "sidemenucontroller")
        let rightViewController = storyBoardMain.instantiateViewController(withIdentifier: "SideRightMenuController")
        
//        let navigationController = UINavigationController(rootViewController: rootViewController)
        
        let sideMenuController = LGSideMenuController(rootViewController: rootViewController,
                                                      leftViewController: leftViewController,
                                                      rightViewController: rightViewController)

        sideMenuController.leftViewWidth = 250.0;
        sideMenuController.rightViewWidth = 250.0;
        sideMenuController.leftViewPresentationStyle = .slideBelow ;
        sideMenuController.rightViewPresentationStyle = .slideBelow ;
        self.window?.rootViewController = sideMenuController
        self.window?.makeKeyAndVisible()
        
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }


}

