--[[

Dynamic (Fine Tuned Word Embeddings LookupTable) CMOT.
When we fine-tune, we make a LookupTable, and set its value to a Word2Vec
dataset.  This is augmented with a '<PADDING>' feature which is forced to
zero, even during optimization.  For any non-massive GPU, you will want
to pass -cullunused, which will trim the LookupTable down to contain only
attested features

]]--

require 'nn'
require 'xlua'
require 'optim'
require 'classutils'
require 'data'
require 'train'
require 'emb'
torch.setdefaulttensortype('torch.FloatTensor')

-----------------------------------------------------
-- Defaults if you dont specify args
-- Note that some arguments depend on which optim
-- is selected, and may be unused for others. Try to
-- provide reasonable args for any algorithm a user selects
-----------------------------------------------------
DEF_TSF = './data/TREC.train.all'
DEF_ESF = './data/TREC.test.all'
DEF_BATCHSZ = 20
DEF_OPTIM = 'adadelta'
DEF_ETA = 0.001
DEF_MOM = 0.0
DEF_DECAY = 1e-9
DEF_DROP = 0.5
DEF_MXLEN = 100
DEF_ESZ = 300
DEF_CMOTSZ = 200
DEF_HSZ = -1 -- No additional projection layer
DEF_EMBED = './data/GoogleNews-vectors-negative300.bin'
DEF_FILE_OUT = './cnn-sentence.model'
DEF_FSZ = '{5}'
DEF_PATIENCE = 50
DEF_EPOCHS = 1000
DEF_PROC = 'gpu'
DEF_CACTIVE = 'relu'
DEF_HACTIVE = 'relu'
DEF_EMBUNIF = 0.01

---------------------------------------------------------------------
-- Make a Softmax output CMOT with Dropout and a word2vec LookupTable
---------------------------------------------------------------------
function createModel(lookupTable, cmotsz, cactive, hsz, hactive, filts, gpu, nc, pdrop)
    local dsz = lookupTable.dsz
    local seq = nn.Sequential()

    seq:add(lookupTable)

    local concat = nn.Concat(2)
    -- Normally just one filter, but allow more if need be
    for i=1,#filts do
       local filtsz = filts[i]
       print('Creating filter of size ' .. filtsz)
       local subseq = nn.Sequential()
       subseq:add(nn.TemporalConvolution(dsz, cmotsz, filtsz))
       subseq:add(activationFor(cactive))
       subseq:add(nn.Max(2))
       subseq:add(nn.Dropout(pdrop))
       concat:add(subseq)
    end
    seq:add(concat)
    -- If you wanted another hidden layer
    if hsz > 0 then
       seq:add(nn.Linear(#filts * cmotsz, hsz))
       seq:add(activationFor(hactive))
       seq:add(nn.Linear(hsz, nc))
    else
       seq:add(nn.Linear(#filts * cmotsz, nc))
    end    
    seq:add(nn.LogSoftMax())
    return gpu and seq:cuda() or seq
end

--------------------------
-- Command line handling
--------------------------
cmd = torch.CmdLine()
cmd:text('Parameters for Dynamic CMOT Network')
cmd:text()
cmd:text('Options:')
cmd:option('-save', DEF_FILE_OUT, 'Save model to')
cmd:option('-embed', DEF_EMBED, 'Word2Vec embeddings')
cmd:option('-embunif', DEF_EMBUNIF, 'Word2Vec initialization for non-attested attributes')
cmd:option('-eta', DEF_ETA, 'Initial learning rate')
cmd:option('-optim', DEF_OPTIM, 'Optimization method (sgd|adagrad|adam)')
cmd:option('-decay', DEF_DECAY, 'Weight decay')
cmd:option('-dropout', DEF_DROP, 'Dropout prob')
cmd:option('-mom', DEF_MOM, 'Momentum for SGD')
cmd:option('-train', DEF_TSF, 'Training file')
cmd:option('-eval', DEF_ESF, 'Testing file')
cmd:option('-epochs', DEF_EPOCHS, 'Number of epochs')
cmd:option('-proc', DEF_PROC, 'Backend (gpu|cpu)')
cmd:option('-batchsz', DEF_BATCHSZ, 'Batch size')
cmd:option('-mxlen', DEF_MXLEN, 'Max number of tokens to use')
cmd:option('-patience', DEF_PATIENCE, 'How many failures to improve until quitting')
cmd:option('-hsz', DEF_HSZ, 'Depth of additional hidden layer')
cmd:option('-cmotsz', DEF_CMOTSZ, 'Depth of convolutional/max-over-time output') 
cmd:option('-cactive', DEF_CACTIVE, 'Activation function following conv')
cmd:option('-filtsz', DEF_FSZ, 'Convolution filter width')
-- Strongly recommend its set to 'true' for non-massive GPUs
cmd:option('-lower', false, 'Lower case words')
cmd:option('-cullunused', false, 'Cull unattested words from Lookup Table')
local opt = cmd:parse(arg)
opt.filtsz = loadstring("return " .. opt.filtsz)()
----------------------------------------
-- Optimization
----------------------------------------
state, optmeth = optimMethod(opt)

----------------------------------------
-- Processing on GPU or CPU
----------------------------------------
opt.gpu = false
if opt.proc == 'gpu' then
   opt.gpu = true
   require 'cutorch'
   require 'cunn'
else
   opt.proc = 'cpu'
end

print('Processing on ' .. opt.proc)


------------------------------------------------------------------------
-- This option is to clip unattested features from the LookupTable, for
-- processing efficiency
-- Reading from eval is not really cheating here
-- We are just culling the set to let the LUT be more compact for tests
-- This data already existed in pre-training!  We are just being optimal
-- here to keep memory footprint small
------------------------------------------------------------------------
local vocab = nil

if opt.cullunused then
   vocab = buildVocab({opt.train, opt.eval})
   print('Removing unattested words')
end

---------------------------------------
-- Minibatches
---------------------------------------
print('Using batch size ' .. opt.batchsz)

-----------------------------------------------
-- Load Word2Vec Model and provide a hook for 
-- zero-ing the weights after each iteration
-----------------------------------------------

w2v = Word2VecLookupTable(opt.embed, vocab, opt.embunif)
function afterhook() 
      w2v.weight[w2v.vocab["<PADDING>"]]:zero()
end
opt.afteroptim = afterhook

print('Loaded word embeddings')
print('Vocab size ' .. w2v.vsz)


---------------------------------------
-- Load Feature Vectors
---------------------------------------
local f2i = {}
ts,f2i = loadTemporalIndices(opt.train, w2v, f2i, opt)
print('Loaded training data')
es,f2i = loadTemporalIndices(opt.eval, w2v, f2i, opt)
print('Loaded test data')
local i2f = revlut(f2i)
print(f2i)
print(#i2f)

---------------------------------------
-- Build model and criterion
---------------------------------------
local crit = createCrit(opt.gpu, #i2f)
local model = createModel(w2v, opt.cmotsz, opt.cactive, opt.hsz, opt.hactive, opt.filtsz, opt.gpu, #i2f, opt.dropout)

local errmin = 1
local lastImproved = 0

for i=1,opt.epochs do
    print('Training epoch ' .. i)
    confusion = optim.ConfusionMatrix(i2f)
    trainEpoch(crit, model, ts, optmeth, confusion, opt)
    confusion = optim.ConfusionMatrix(i2f)
    local erate = test(model, es, confusion, opt)
    if erate < errmin then
       errmin = erate
       lastImproved = i
       print('Lowest error achieved yet -- writing model')
       saveModel(model, opt.save, opt.gpu)
    end
    if (i - lastImproved) > opt.patience then
       print('Stopping due to persistent failures to improve')
       break
    end
end

print('Highest test acc: ' .. (100 * (1. - errmin)))
