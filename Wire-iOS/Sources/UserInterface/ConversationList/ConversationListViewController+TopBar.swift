//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//


import UIKit
import Cartography

extension ConversationListViewController {
    
    @objc public var showSpaces: Bool {
        set {
            UIView.performWithoutAnimation {
                if Space.spaces.count > 0 {
                    self.spacesView?.removeFromSuperview()
                    self.spacesView = SpaceSelectorView(spaces: Space.spaces)
                    
                    self.topBar.middleView = self.spacesView
                    self.topBar.leftSeparatorLineView.alpha = 1
                    self.topBar.rightSeparatorLineView.alpha = 1
                    
                    let scrolledOffFromTop = self.listContentController.collectionView?.contentOffset.y > 0
                    self.spacesImagesCollapsed = scrolledOffFromTop
                    self.spacesView?.imagesCollapsed = scrolledOffFromTop
                    self.listContentController.collectionView?.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
                    if !scrolledOffFromTop {
                        self.listContentController.collectionView?.contentOffset = CGPoint(x: 0, y: -16)
                    }
                }
                else {
                    let titleLabel = UILabel()
                    
                    titleLabel.font = FontSpec(.medium, .semibold).font
                    titleLabel.textColor = ColorScheme.default().color(withName: ColorSchemeColorTextForeground, variant: .dark)
                    titleLabel.text = "list.title".localized.uppercased()
                    
                    self.topBar.middleView = titleLabel
                    
                    self.listContentController.collectionView?.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                    self.spacesImagesCollapsed = true
                }
            }
        }
        
        get {
            return Space.spaces.count > 0
        }
    }
    
    public func updateSpaces() {
        self.showSpaces = Space.spaces.count > 0
    }
    
    public func createTopBar() {
        let profileButton = IconButton()
        
        profileButton.setIcon(.selfProfile, with: .tiny, for: UIControlState())
        profileButton.addTarget(self, action: #selector(settingsButtonTapped(_:)), for: .touchUpInside)
        profileButton.accessibilityIdentifier = "bottomBarSettingsButton"
        profileButton.setIconColor(.white, for: .normal)
        
        if let imageView = profileButton.imageView, let user = ZMUser.selfUser() {
            let newDevicesDot = NewDevicesDot(user: user)
            profileButton.addSubview(newDevicesDot)
            
            constrain(newDevicesDot, imageView) { newDevicesDot, imageView in
                newDevicesDot.top == imageView.top - 3
                newDevicesDot.trailing == imageView.trailing + 3
                newDevicesDot.width == 8
                newDevicesDot.height == 8
            }
        }
        
        self.topBar = ConversationListTopBar()
        
        self.view.addSubview(self.topBar)
        self.updateSpaces()
        self.topBar.leftView = profileButton
    }
    
    @objc public func settingsButtonTapped(_ sender: AnyObject) {
        self.presentSettings()
    }
}
