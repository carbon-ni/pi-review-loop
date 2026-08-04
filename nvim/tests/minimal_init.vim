" Minimal init for plenary test children.
" Adds plenary + the plugin root to runtimepath so requires resolve and the
" PlenaryBustedFile command is available.
let s:plenary = $PLENARY_PATH
if s:plenary ==# '' | let s:plenary = $HOME . '/.local/share/nvim/lazy/plenary.nvim' | endif
let s:root = $REVIEW_LOOP_ROOT
let s:diffview = $DIFFVIEW_PATH
if s:diffview ==# '' | let s:diffview = $HOME . '/.local/share/nvim/lazy/diffview.nvim' | endif
execute 'set rtp+=' . fnameescape(s:plenary)
if isdirectory(s:diffview) | execute 'set rtp+=' . fnameescape(s:diffview) | endif
if s:root !=# ''
  execute 'set rtp+=' . fnameescape(s:root)
endif
