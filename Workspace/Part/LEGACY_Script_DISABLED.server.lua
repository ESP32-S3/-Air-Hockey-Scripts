debounce = false
function onTouched(hit) -- When the button is touched...
if debounce == false then
debounce = false
local s = Instance.new("Sound") -- Create a new sound file
s.Name = "Sound" -- Dont change this.
s.SoundId = "http://www.roblox.com/asset/?id=158935706" -- SoundId! Type here yours.
s.Volume = 0.8 -- Volume. 1 is the strongest, you can change it to whatever you want.
s.Looped = false -- Change this to true if you want the sound to loop (not recommended)
s.archivable = false -- Dont touch.

s.Parent = game.Workspace

wait(0)

s:play() -- Play our new sound!
end
end

script.Parent.Touched:connect(onTouched)
