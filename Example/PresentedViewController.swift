//
//  PresentedViewController.swift
//
//  Created by Jon Kent on 12/14/15.
//  Copyright © 2015 Jon Kent. All rights reserved.
//

import UIKit

class PresentedViewController: UIViewController {

    @IBAction fileprivate func close() {
        self.dismiss(animated: true, completion: nil)
    }
    
  var cloj: (() -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    print(#file, #function)
    let btn = UIButton(type: .custom)
    btn.setTitle("Ixit", for: .normal)

    btn.frame = CGRect(x: 100, y: 200, width: 200, height: 200)

    view.addSubview(btn)

    btn.addTarget(self, action: #selector(PresentedViewController.touch(_:)), for: .touchUpInside)
  }

  @objc
  func touch(_ id: Any) {

    cloj?()
  }

}
