//
//  TopMenuController.swift
//  SceneSwap
//
//  Created by Rizwan on 4/18/18.
//  Copyright © 2018 Rizwan. All rights reserved.
//

import UIKit

class TopMenuController: UIViewController {

    @IBOutlet weak var DepthButton: UIButton!
    @IBOutlet weak var faceButton: UIButton!
    @IBOutlet weak var threeDButton: UIButton!
    @IBOutlet weak var fpsButton: UIButton!
    
    
    var con : ViewController!
    
    
    @IBOutlet var topMenuButtons: [UIButton]!
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        fpsButton.setTitleColor(UIColor.black, for: .normal)
        fpsButton.setTitleColor(UIColor.blue, for: .selected)
        
        threeDButton.setTitleColor(UIColor.black, for: .normal)
        threeDButton.setTitleColor(UIColor.blue, for: .selected)
        
        faceButton.setTitleColor(UIColor.black, for: .normal)
        faceButton.setTitleColor(UIColor.blue, for: .selected)
        
        DepthButton.setTitleColor(UIColor.black, for: .normal)
        DepthButton.setTitleColor(UIColor.blue, for: .selected)
        
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

    @IBAction func hideMenu(_ sender: UIButton) {
        topMenu.view.removeFromSuperview()
    }
    @IBAction func buttonSelected(_ sender: UIButton) {
        print(con)
        if sender.tag == 0{
            if sender.isSelected == true{
                app.fpsStop()
            }else{
                app.fpsStart()
            }
        }
        if sender.tag == 1{
            if sender.isSelected == true{
            }else{
                self.DepthButton.isSelected = false
                self.faceButton.isSelected = false
            }
        }
        if sender.tag == 2{
            if sender.isSelected == true{
            }else{
                self.DepthButton.isSelected = false
                self.threeDButton.isSelected = false
            }
        }
        if sender.tag == 3{
            if sender.isSelected == true{
            }else{
                self.threeDButton.isSelected = false
                self.faceButton.isSelected = false
            }
            
            con.backValueNil()
        }
        topMenu.view.removeFromSuperview()
        sender.isSelected = !sender.isSelected
    }
    
    
    
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}
