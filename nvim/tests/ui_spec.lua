local config = require("review-loop.config")
local ui = require("review-loop.ui")
local eq = assert.are.same

describe("review feedback delivery", function()
  local feedback_path

  before_each(function()
    feedback_path = vim.fn.tempname() .. ".md"
    config.setup({ feedback_file = feedback_path })
    vim.fn.setreg("+", "previous clipboard")
  end)

  after_each(function()
    vim.fn.delete(feedback_path)
    config.config = nil
  end)

  it("submits the review and copies the feedback file path to the + register when sending", function()
    local submitted = false
    local controller = setmetatable({}, { __index = ui })
    controller._composed = function()
      return "Please address this feedback"
    end
    controller.submit = function(self)
      submitted = true
      return self:deliver(self:_composed())
    end

    controller:send_feedback()

    eq(true, submitted)
    eq(feedback_path, vim.fn.getreg("+"))
    eq("Please address this feedback", table.concat(vim.fn.readfile(feedback_path), "\n"))
  end)

  it("keeps the clipboard unchanged when there are no comments to send", function()
    local controller = setmetatable({}, { __index = ui })
    controller._composed = function()
      return ""
    end

    controller:send_feedback()

    eq("previous clipboard", vim.fn.getreg("+"))
    eq(0, vim.fn.filereadable(feedback_path))
  end)
end)
