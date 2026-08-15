function onTouched(hit) 
if hit.Name == "ball" then -- The footballs themselves are named "Handle". If this script is being used for hockey or something, change the name to the puck's name. If it's kept at handle, any handheld tool will activate the message. 
local m = Instance.new("Message") 
m.Parent = game.Workspace 
m.Text = "The away team has scored a goal!" 
wait(3) 
m:remove() 
end 
end 

script.Parent.Touched:connect(onTouched)  