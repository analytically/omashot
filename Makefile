# snapmenu — developer entry points.
#
#   make test     everything that must pass before this goes near a live shell
#   make native   build the native clipboard helper (bin/snapmenu-clipboard)
#   make deploy   copy the tree into the plugin directory and restart the shell
#   make manual   the three checks that need a real compositor and a real session
#   make notes    the acceptance criteria for the parts no runner can cover

PLUGIN_ID := io.github.analytically.snapmenu
PLUGIN_DIR := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)

.PHONY: test native deploy manual notes

test:
	@tests/run.sh

native:
	@native/build.sh

deploy: test
	@tests/deploy.sh

manual:
	@tests/manual/menu_dropdown.sh
	@tests/manual/keyboard_pick.sh
	@tests/manual/freeze_crop_identity.sh

notes:
	@printf '%s\n' \
	  'What the manual checks assert (run them with: make manual):' \
	  '  freeze_crop_identity.sh  the cropped shot is the frozen frame, pixel for pixel' \
	  '  keyboard_pick.sh         Tab selects a window and Enter captures exactly its pixels' \
	  'Both need a running omarchy-shell, Hyprland and wtype.'
